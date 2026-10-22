import Darwin
import YabaiCore

//
// NOTE: The client side of `yabai -m`: it sends the arguments to the socket of the daemon and prints the response. A
// response that starts with FAILURE_MESSAGE goes to stderr without that byte, and the client exits with EXIT_FAILURE.
// Like the C version, the first byte of every read is checked, and each read is printed up to its first null byte.
// Ported from client_send_message in src/yabai.c.
//

enum Client {
  /// `error` (src/misc/log.h): the text on stderr, then exit with EXIT_FAILURE.
  static func fail(_ text: String) -> Never {
    writeAll(STDERR_FILENO, Array(text.utf8))
    exit(EXIT_FAILURE)
  }

  static func writeAll(_ fd: Int32, _ bytes: some Collection<UInt8>) {
    let bytes = Array(bytes)
    var written = 0
    while written < bytes.count {
      let result = bytes.withUnsafeBytes {
        write(fd, $0.baseAddress! + written, bytes.count - written)
      }
      if result <= 0 { return }
      written += result
    }
  }

  /// The seconds `send` waits for a response when YABAI_CLIENT_TIMEOUT is not set or not a positive integer. The
  /// default is long enough for commands that wait, such as native fullscreen toggles.
  static let defaultResponseTimeout = 30

  /// The receive timeout in seconds for a value of YABAI_CLIENT_TIMEOUT; invalid values give the default.
  static func responseTimeout(_ value: String?) -> Int {
    guard let value, let seconds = Int(value), seconds > 0 else { return defaultResponseTimeout }
    return seconds
  }

  /// The working directory of the client, or nil when it cannot be read.
  static func workingDirectory() -> String? {
    var buffer = [CChar](repeating: 0, count: Int(PATH_MAX))
    guard getcwd(&buffer, buffer.count) != nil else { return nil }
    return String(decoding: buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
  }

  /// The tokens of `yabai -m batch`, read from stdin. Nothing is sent when a line of stdin cannot be read.
  static func batchTokens(_ arguments: [[UInt8]]) -> [[UInt8]] {
    guard arguments.count == 1 else {
      fail("yabai-msg: batch reads its commands from stdin and takes no arguments..\n")
    }

    var input: [UInt8] = []
    var buffer = [UInt8](repeating: 0, count: 4096)
    while true {
      let count = buffer.withUnsafeMutableBytes { read(STDIN_FILENO, $0.baseAddress, $0.count) }
      if count < 0 && errno == EINTR { continue }
      if count <= 0 { break }
      input += buffer[0..<count]
    }

    let commands: [[String]]
    do {
      commands = try parseBatchInput(String(decoding: input, as: UTF8.self))
    } catch {
      fail("yabai-msg: batch: line \(error.line): \(error.reason), nothing sent..\n")
    }

    let tokens = BatchMessage.encode(commands)
    if ClientMessage.encode(tokens).count - MemoryLayout<Int32>.size > MessageLoop.maxMessageLength
    {
      fail("yabai-msg: batch is longer than 1 MiB, nothing sent..\n")
    }
    return tokens
  }

  /// `client_send_message`: arguments are the arguments after `-m`.
  static func send(_ arguments: [[UInt8]]) -> Int32 {
    if arguments.isEmpty {
      fail("yabai-msg: no arguments given! abort..\n")
    }

    // NOTE: `batch` with no further argument reads its commands from stdin (batchTokens); the daemon gets them as a batch.
    let tokens =
      arguments.first == Array(BatchMessage.domain.utf8) ? batchTokens(arguments) : arguments

    // NOTE: `config --check <file>` and `config --reload <file>` send the file as an absolute path: the daemon resolves
    // a relative one in its own directory.
    let arguments =
      workingDirectory().map { ConfigFileSearch.resolvingConfigFile(tokens, workingDirectory: $0) }
      ?? tokens

    guard let user = ProcessEnvironment.currentUser() else {
      fail("yabai-msg: 'env USER' not set! abort..\n")
    }

    let message = ClientMessage.encode(arguments)

    var sockfd: Int32 = -1
    if !UnixSocket.open(&sockfd) {
      fail("yabai-msg: failed to open socket..\n")
    }

    if !UnixSocket.connect(sockfd, to: "/tmp/yabai_\(user).socket") {
      fail("yabai-msg: failed to connect to socket..\n")
    }

    // NOTE: A subscription has no response time limit: its events come whenever they happen, and the daemon ends it.
    let subscribing = tokens.first == Array(Domain.subscribe.utf8)
    if !subscribing {
      var timeout = timeval(
        tv_sec: responseTimeout(getenv("YABAI_CLIENT_TIMEOUT").map { String(cString: $0) }),
        tv_usec: 0)
      setsockopt(sockfd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
    }

    var sent = 0
    while sent < message.count {
      let bytes = message.withUnsafeBytes {
        Darwin.send(sockfd, $0.baseAddress! + sent, message.count - sent, 0)
      }
      if bytes == -1 { fail("yabai-msg: failed to send data..\n") }
      sent += bytes
    }

    shutdown(sockfd, SHUT_WR)

    var result = EXIT_SUCCESS
    var output = STDOUT_FILENO
    var response = [UInt8](repeating: 0, count: Int(BUFSIZ))

    while true {
      let bytesRead = response.withUnsafeMutableBytes {
        read(sockfd, $0.baseAddress, Int(BUFSIZ) - 1)
      }
      if bytesRead == -1 && (errno == EAGAIN || errno == EWOULDBLOCK) {
        fail("yabai-msg: timed out waiting for a response..\n")
      }

      if bytesRead <= 0 { break }

      var chunk = response[0..<bytesRead]
      if chunk.first == Response.failureByte {
        result = EXIT_FAILURE
        output = STDERR_FILENO
        chunk = chunk.dropFirst()
      }

      writeAll(output, chunk.prefix { $0 != 0 })
    }

    UnixSocket.close(sockfd)
    return result
  }
}
