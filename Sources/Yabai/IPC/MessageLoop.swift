import Darwin
import Foundation
import YabaiC
import YabaiCore

//
// NOTE: The socket of the daemon (/tmp/yabai_$USER.socket). A thread accepts the connections and posts a DAEMON_MESSAGE
// event for each; the handler of that event reads the message and writes the response on the event loop
// (daemon_message_handle). Ported from src/message.c and the DAEMON_MESSAGE handler of src/event_handlers_system.c.
//

@_cdecl("message_loop_begin")
func message_loop_begin(_ socketPath: UnsafeMutablePointer<CChar>?) -> Bool
{
    guard let socketPath else { return false }

    var address = sockaddr_un()
    address.sun_family = sa_family_t(AF_UNIX)
    withUnsafeMutableBytes(of: &address.sun_path) { sunPath in
        let length = min(strlen(socketPath), sunPath.count - 1)
        sunPath.copyBytes(from: UnsafeRawBufferPointer(start: socketPath, count: length))
        sunPath[length] = 0
    }
    unlink(socketPath)

    let sockfd = socket(AF_UNIX, SOCK_STREAM, 0)
    if sockfd == -1 {
        return false
    }

    let bound = withUnsafePointer(to: &address) {
        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(sockfd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
    }
    if bound == -1 {
        return false
    }

    if chmod(socketPath, 0o600) != 0 {
        return false
    }

    if listen(sockfd, SOMAXCONN) == -1 {
        return false
    }

    _ = fcntl(sockfd, F_SETFD, FD_CLOEXEC | fcntl(sockfd, F_GETFD))

    Thread.detachNewThread {
        messageLoopRun(sockfd)
    }

    return true
}

private func messageLoopRun(_ listener: Int32) -> Never
{
    while true {
        let sockfd = accept(listener, nil, nil)
        if sockfd == -1 { continue }

        //
        // NOTE: The message is read and the response written on the event loop thread. A client that
        // stalls must not be able to block it, so reads and writes on the socket time out.
        //

        var timeout = timeval(tv_sec: 1, tv_usec: 0)
        setsockopt(sockfd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        setsockopt(sockfd, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))

        event_loop_post(event_loop_global(), DAEMON_MESSAGE, nil, sockfd)
    }
}

//
// NOTE: The message is a native-endian int with its length, then the null-separated tokens (ClientMessage.encode). Two
// null bytes after the message end it even when a client left out its empty last token, which the C version did not
// guard against.
//

@_cdecl("daemon_message_handle")
func daemon_message_handle(_ sockfd: Int32)
{
    var bytesToRead: Int32 = 0
    guard read(sockfd, &bytesToRead, MemoryLayout<Int32>.size) == MemoryLayout<Int32>.size, bytesToRead >= 0 else {
        socket_close(sockfd)
        return
    }

    var message = [CChar](repeating: 0, count: Int(bytesToRead) + 2)
    var bytesRead = 0

    repeat {
        let currentRead = message.withUnsafeMutableBytes { read(sockfd, $0.baseAddress! + bytesRead, Int(bytesToRead) - bytesRead) }
        if currentRead <= 0 { break }

        bytesRead += currentRead
    } while bytesRead < bytesToRead

    guard bytesRead == bytesToRead else {
        socket_close(sockfd)
        return
    }

    var response = Response()
    message.withUnsafeMutableBufferPointer { buffer in
        debug_message("EVENT_HANDLER_DAEMON_MESSAGE", buffer.baseAddress)
        handleMessage(&response, buffer.baseAddress!)
    }

    ResponseWriter(sockfd: sockfd).send(response)
}

/// The connection of a client. It replaces the `FILE *rsp` that the C version made of the socket with fdopen: the
/// handlers write into a Response, which is sent at the end.
struct ResponseWriter
{
    let sockfd: Int32

    //
    // NOTE: Like fflush on the FILE, the write stops at the first error, e.g. when the send timeout expires or the
    // client is gone (SIGPIPE is ignored). The socket is closed either way, like fclose did.
    //

    func send(_ response: Response)
    {
        var written = 0
        while written < response.bytes.count {
            let result = response.bytes.withUnsafeBytes { write(sockfd, $0.baseAddress! + written, response.bytes.count - written) }
            if result <= 0 { break }
            written += result
        }

        close(sockfd)
    }
}

/// `handle_message`: runs the commands of a message. The domains other than config are still C and write into a FILE.
func handleMessage(_ response: inout Response, _ message: UnsafeMutablePointer<CChar>)
{
    var cursor: UnsafeMutablePointer<CChar>? = message
    let domain = get_token(&cursor)
    let name = Token(domain)

    if name.equals(Domain.config) {
        withUnsafeMutablePointer(to: &cursor) { cursor in
            var source = CMessage(cursor: cursor)
            handleDomainConfig(&response, name, &source)
        }
    } else if name.equals(Domain.display) {
        response.appendWritten { handle_domain_display($0, domain, cursor) }
    } else if name.equals(Domain.space) {
        response.appendWritten { handle_domain_space($0, domain, cursor) }
    } else if name.equals(Domain.window) {
        response.appendWritten { handle_domain_window($0, domain, cursor) }
    } else if name.equals(Domain.query) {
        response.appendWritten { handle_domain_query($0, domain, cursor) }
    } else if name.equals(Domain.rule) {
        response.appendWritten { handle_domain_rule($0, domain, cursor) }
    } else if name.equals(Domain.signal) {
        response.appendWritten { handle_domain_signal($0, domain, cursor) }
    } else {
        response.fail("unknown domain '\(name)'\n")
    }
}

/// The C entry point of handleMessage, for the golden replay of the C tests (tests/src/golden.c).
@_cdecl("handle_message")
func handle_message(_ rsp: UnsafeMutablePointer<FILE>?, _ message: UnsafeMutablePointer<CChar>?)
{
    guard let message else { return }

    var response = Response()
    handleMessage(&response, message)
    response.write(to: rsp)
}
