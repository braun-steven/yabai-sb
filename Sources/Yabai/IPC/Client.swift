import Darwin
import YabaiCore

/// Sends one versioned request and renders structured replies to the two CLI streams.
enum Client {
  /// Prints a client failure and exits.
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
      if result < 0 && errno == EINTR { continue }
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

  private static func batchCommands(_ arguments: [[UInt8]]) -> [[String]] {
    guard arguments.count == 1 else {
      fail("yabai-msg: batch reads its commands from stdin and takes no arguments..\n")
    }
    var input: [UInt8] = []
    var buffer = [UInt8](repeating: 0, count: 4096)
    while true {
      let count = buffer.withUnsafeMutableBytes { read(STDIN_FILENO, $0.baseAddress, $0.count) }
      if count < 0 && errno == EINTR { continue }
      guard count >= 0 else { fail("yabai-msg: failed to read batch input, nothing sent..\n") }
      if count == 0 { break }
      input += buffer[..<count]
      guard input.count <= IPCProtocol.requestLimit else {
        fail("yabai-msg: batch is longer than 1 MiB, nothing sent..\n")
      }
    }
    do {
      return try parseBatchInput(String(decoding: input, as: UTF8.self))
    } catch {
      fail("yabai-msg: batch: line \(error.line): \(error.reason), nothing sent..\n")
    }
  }

  /// Resolves file arguments before transport, for ordinary commands and each batch command alike.
  static func request(_ arguments: [[UInt8]], batch: [[String]]? = nil) -> IPCRequest {
    let directory = workingDirectory()
    func resolved(_ words: [String]) -> [String] {
      let bytes = words.map { Array($0.utf8) }
      let result =
        directory.map {
          ConfigFileSearch.resolvingConfigFile(bytes, workingDirectory: $0)
        } ?? bytes
      return result.map { String(decoding: $0, as: UTF8.self) }
    }
    if let batch { return .batch(commands: batch.map(resolved)) }
    return .command(arguments: resolved(arguments.map { String(decoding: $0, as: UTF8.self) }))
  }

  /// Arguments are the argv values after -m; a batch is read completely before sending anything.
  static func send(_ arguments: [[UInt8]]) -> Int32 {
    guard !arguments.isEmpty else { fail("yabai-msg: no arguments given! abort..\n") }
    let batch =
      arguments.first == Array(Domain.batch.rawValue.utf8) ? batchCommands(arguments) : nil
    let request = request(arguments, batch: batch)
    guard let user = ProcessEnvironment.currentUser() else {
      fail("yabai-msg: 'env USER' not set! abort..\n")
    }
    let timeout = responseTimeout(getenv("YABAI_CLIENT_TIMEOUT").map { String(cString: $0) })
    do {
      let frame = try IPCProtocol.encode(request, limit: IPCProtocol.requestLimit)
      let connection = try IPCConnection.connect(
        path: "/tmp/yabai_\(user).socket", timeout: timeout)
      try connection.write(frame, timeout: timeout)
      connection.finishRequest()

      var renderer = IPCRenderer(request: request)
      while !renderer.completed {
        guard
          let payload = try connection.readFrame(
            limit: IPCProtocol.responseLimit, timeout: renderer.subscribed ? nil : timeout)
        else { break }
        let reply = try IPCProtocol.decode(IPCReply.self, payload: payload)
        let output = try renderer.consume(reply)
        writeAll(STDOUT_FILENO, Array(output.stdout.utf8))
        writeAll(STDERR_FILENO, Array(output.stderr.utf8))
      }
      return try renderer.finish() ? EXIT_SUCCESS : EXIT_FAILURE
    } catch {
      fail("yabai-msg: \(error)..\n")
    }
  }
}
