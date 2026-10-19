import Darwin
import Foundation
import CPrivate
import YabaiCore

//
// NOTE: The socket of the daemon (/tmp/yabai_$USER.socket). A thread accepts the connections and posts a
// daemonMessage event for each; the handler of that event (MessageLoop.handle) reads the message and writes the
// response on the event loop.
//

enum MessageLoop
{
    static func begin(socketPath: String) -> Bool
    {
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        withUnsafeMutableBytes(of: &address.sun_path) { sunPath in
            let path = Array(socketPath.utf8.prefix(sunPath.count - 1))
            sunPath.copyBytes(from: path)
            sunPath[path.count] = 0
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
            run(sockfd)
        }

        return true
    }

    private static func run(_ listener: Int32) -> Never
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
    // null bytes after the message end it even when a client left out its empty last token.
    //

    @WM static func handle(_ sockfd: Int32)
    {
        var bytesToRead: Int32 = 0
        guard Darwin.read(sockfd, &bytesToRead, MemoryLayout<Int32>.size) == MemoryLayout<Int32>.size, bytesToRead >= 0 else {
            UnixSocket.close(sockfd)
            return
        }

        var message = [CChar](repeating: 0, count: Int(bytesToRead) + 2)
        var bytesRead = 0

        repeat {
            let currentRead = message.withUnsafeMutableBytes { Darwin.read(sockfd, $0.baseAddress! + bytesRead, Int(bytesToRead) - bytesRead) }
            if currentRead <= 0 { break }

            bytesRead += currentRead
        } while bytesRead < bytesToRead

        guard bytesRead == bytesToRead else {
            UnixSocket.close(sockfd)
            return
        }

        message.withUnsafeMutableBufferPointer { debugMessage("EVENT_HANDLER_DAEMON_MESSAGE", $0.baseAddress) }

        var response = Response()
        var tokens = Message(message.map { UInt8(bitPattern: $0) })
        handleMessage(&response, &tokens)

        ResponseWriter(sockfd: sockfd).send(response)
    }
}

/// The connection of a client: the handlers write into a Response, which is sent at the end.
struct ResponseWriter
{
    let sockfd: Int32

    //
    // NOTE: The write stops at the first error, e.g. when the send timeout expires or the
    // client is gone (SIGPIPE is ignored). The socket is closed either way.
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

// NOTE: Runs the commands of a message from first on. A command returns false to stop silently. A failing command
// writes its failure and the next command still runs, unless the failure stops the message (CommandError.stopsMessage):
// handleMessage writes that one.
//

@WM func runCommands<Source: TokenSource>(_ rsp: inout Response, _ message: inout Source, from first: Token, _ run: (inout Response, inout Source, Token) throws(CommandError) -> Bool) throws(CommandError)
{
    var command = first
    while command.isValid {
        do {
            if try run(&rsp, &message, command) == false { return }
        } catch where !error.stopsMessage {
            rsp.fail(error)
        }
        command = message.next()
    }
}

/// Runs the commands of a message and writes the failure that ends it.
@WM func handleMessage(_ response: inout Response, _ message: inout Message)
{
    do {
        try handleDomain(&response, &message)
    } catch {
        response.fail(error)
    }
}

//
// NOTE: The throw of an unknown domain is kept out of handleMessage's do block: a do block that throws directly infers
// any Error for its catch, not CommandError.
//

@WM private func handleDomain(_ response: inout Response, _ message: inout Message) throws(CommandError)
{
    let domain = message.next()

    if domain.equals(Domain.config) {
        try handleDomainConfig(&response, domain, &message)
    } else if domain.equals(Domain.display) {
        try handleDomainDisplay(&response, domain, &message)
    } else if domain.equals(Domain.space) {
        try handleDomainSpace(&response, domain, &message)
    } else if domain.equals(Domain.window) {
        try handleDomainWindow(&response, domain, &message)
    } else if domain.equals(Domain.query) {
        try handleDomainQuery(&response, domain, &message)
    } else if domain.equals(Domain.rule) {
        try handleDomainRule(&response, domain, &message)
    } else if domain.equals(Domain.signal) {
        try handleDomainSignal(&response, domain, &message)
    } else {
        throw CommandError("unknown domain '\(domain)'\n")
    }
}
