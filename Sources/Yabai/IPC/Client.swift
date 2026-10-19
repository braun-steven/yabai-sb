import Darwin
import YabaiCore

//
// NOTE: The client side of `yabai -m`: it sends the arguments to the socket of the daemon and prints the response. A
// response that starts with FAILURE_MESSAGE goes to stderr without that byte, and the client exits with EXIT_FAILURE.
// Like the C version, the first byte of every read is checked, and each read is printed up to its first null byte.
// Ported from client_send_message in src/yabai.c.
//

enum Client
{
    /// `error` (src/misc/log.h): the text on stderr, then exit with EXIT_FAILURE.
    static func fail(_ text: String) -> Never
    {
        writeAll(STDERR_FILENO, Array(text.utf8))
        exit(EXIT_FAILURE)
    }

    static func writeAll(_ fd: Int32, _ bytes: some Collection<UInt8>)
    {
        let bytes = Array(bytes)
        var written = 0
        while written < bytes.count {
            let result = bytes.withUnsafeBytes { write(fd, $0.baseAddress! + written, bytes.count - written) }
            if result <= 0 { return }
            written += result
        }
    }

    /// `client_send_message`: arguments are the arguments after `-m`.
    static func send(_ arguments: [[UInt8]]) -> Int32
    {
        if arguments.isEmpty {
            fail("yabai-msg: no arguments given! abort..\n")
        }

        guard let user = getenv("USER") else {
            fail("yabai-msg: 'env USER' not set! abort..\n")
        }

        let message = ClientMessage.encode(arguments)

        var sockfd: Int32 = -1
        if !UnixSocket.open(&sockfd) {
            fail("yabai-msg: failed to open socket..\n")
        }

        if !UnixSocket.connect(sockfd, to: "/tmp/yabai_\(String(cString: user)).socket") {
            fail("yabai-msg: failed to connect to socket..\n")
        }

        var sent = 0
        while sent < message.count {
            let bytes = message.withUnsafeBytes { Darwin.send(sockfd, $0.baseAddress! + sent, message.count - sent, 0) }
            if bytes == -1 { fail("yabai-msg: failed to send data..\n") }
            sent += bytes
        }

        shutdown(sockfd, SHUT_WR)

        var result = EXIT_SUCCESS
        var output = STDOUT_FILENO
        var response = [UInt8](repeating: 0, count: Int(BUFSIZ))

        while true {
            let bytesRead = response.withUnsafeMutableBytes { read(sockfd, $0.baseAddress, Int(BUFSIZ) - 1) }
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
