import Darwin
import Foundation
import CPrivate
import Logging
import YabaiCore

//
// NOTE: The socket of the daemon (/tmp/yabai_$USER.socket). A thread accepts the connections, reads each message and
// posts it as a daemonMessage event; the handler of that event (MessageLoop.handle) runs its commands on the event loop
// and hands the response to a serial queue that writes it.
//

/// A message of a client: its tokens, read by the socket thread, and the socket its response goes to.
struct DaemonMessage: Sendable
{
    let sockfd: Int32
    let bytes: [UInt8]

    /// The null-separated tokens, up to the empty token that ends them, joined by spaces.
    var text: String
    {
        let tokens = bytes.split(separator: 0, omittingEmptySubsequences: false).prefix { !$0.isEmpty }
        return tokens.map { String(decoding: $0, as: UTF8.self) }.joined(separator: " ")
    }
}

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
            // NOTE: This thread reads the message and the queue of the responses writes the response, so a client that
            // stalls cannot block the event loop; reads and writes on the socket time out, so it cannot block the other
            // clients for long either.
            //

            var timeout = timeval(tv_sec: 1, tv_usec: 0)
            setsockopt(sockfd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
            setsockopt(sockfd, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))

            guard let bytes = readMessage(sockfd) else {
                UnixSocket.close(sockfd)
                continue
            }

            EventLoop.post(.daemonMessage(DaemonMessage(sockfd: sockfd, bytes: bytes)))
        }
    }

    //
    // NOTE: The message is a native-endian int with its length, then the null-separated tokens (ClientMessage.encode). Two
    // null bytes after the message end it even when a client left out its empty last token.
    //

    /// Reads the message of a client; nil when the client sent no complete message.
    private static func readMessage(_ sockfd: Int32) -> [UInt8]?
    {
        var bytesToRead: Int32 = 0
        guard Darwin.read(sockfd, &bytesToRead, MemoryLayout<Int32>.size) == MemoryLayout<Int32>.size, bytesToRead >= 0 else {
            return nil
        }

        var message = [UInt8](repeating: 0, count: Int(bytesToRead) + 2)
        var bytesRead = 0

        repeat {
            let currentRead = message.withUnsafeMutableBytes { Darwin.read(sockfd, $0.baseAddress! + bytesRead, Int(bytesToRead) - bytesRead) }
            if currentRead <= 0 { break }

            bytesRead += currentRead
        } while bytesRead < bytesToRead

        guard bytesRead == bytesToRead else {
            return nil
        }

        return message
    }

    //
    // NOTE: The commands run synchronously, without an await. Other events could not run at an await either (the
    // event loop awaits the handler before it takes the next one), the commands of a message rely on the state the
    // earlier ones left (acting window, selectors), and the autorelease pool of the event cannot span an await.
    // Waits inside commands (toggleNativeFullscreen, SpaceID.waitForWindow) block yabai.wm, which runs no other
    // code after startup.
    //

    /// Runs the commands of a message and hands its response to the queue of the responses.
    @WM static func handle(_ message: DaemonMessage)
    {
        Logger.ipc.debug("message: \(message.text)")

        var response = Response()
        var tokens = Message(message.bytes)
        handleMessage(&response, &tokens)

        send(response, to: message.sockfd)
    }

    //
    // NOTE: The responses are written on their own serial queue, in the order of the messages, so a client that does
    // not read its response cannot block the event loop. The write stops at the first error, e.g. when the send
    // timeout expires or the client is gone (SIGPIPE is ignored). The socket is closed either way.
    //

    private static let responses = DispatchSerialQueue(label: "yabai.ipc")

    /// Writes the response to the client and closes its socket, on the queue of the responses.
    private static func send(_ response: Response, to sockfd: Int32)
    {
        responses.async {
            var written = 0
            while written < response.bytes.count {
                let result = response.bytes.withUnsafeBytes { Darwin.write(sockfd, $0.baseAddress! + written, response.bytes.count - written) }
                if result <= 0 { break }
                written += result
            }

            Darwin.close(sockfd)
        }
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
