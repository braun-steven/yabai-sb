import Darwin
import Foundation
import CPrivate
import YabaiCore

//
// NOTE: The socket of the daemon (/tmp/yabai_$USER.socket). A thread accepts the connections and posts a DAEMON_MESSAGE
// event for each; the handler of that event reads the message and writes the response on the event loop
// (daemon_message_handle). Ported from src/message.c and the DAEMON_MESSAGE handler of src/event_handlers_system.c.
//

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

        EventLoop.post(.daemonMessage(sockfd: sockfd))
    }
}

//
// NOTE: The message is a native-endian int with its length, then the null-separated tokens (ClientMessage.encode). Two
// null bytes after the message end it even when a client left out its empty last token, which the C version did not
// guard against.
//

func daemon_message_handle(_ sockfd: Int32)
{
    WM.assumeIsolated { daemonMessageHandle(sockfd) }
}

@WM private func daemonMessageHandle(_ sockfd: Int32)
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

    message.withUnsafeMutableBufferPointer { debug_message("EVENT_HANDLER_DAEMON_MESSAGE", $0.baseAddress) }

    var response = Response()
    var tokens = Message(message.map { UInt8(bitPattern: $0) })
    handleMessage(&response, &tokens)

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

/// `handle_message`: runs the commands of a message.
@WM func handleMessage(_ response: inout Response, _ message: inout Message)
{
    let domain = message.next()

    if domain.equals(Domain.config) {
        handleDomainConfig(&response, domain, &message)
    } else if domain.equals(Domain.display) {
        handleDomainDisplay(&response, domain, &message)
    } else if domain.equals(Domain.space) {
        handleDomainSpace(&response, domain, &message)
    } else if domain.equals(Domain.window) {
        handleDomainWindow(&response, domain, &message)
    } else if domain.equals(Domain.query) {
        handleDomainQuery(&response, domain, &message)
    } else if domain.equals(Domain.rule) {
        handleDomainRule(&response, domain, &message)
    } else if domain.equals(Domain.signal) {
        handleDomainSignal(&response, domain, &message)
    } else {
        response.fail("unknown domain '\(domain)'\n")
    }
}
