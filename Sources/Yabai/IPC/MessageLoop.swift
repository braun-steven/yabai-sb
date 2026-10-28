import Darwin
import Foundation
import Logging
import YabaiCore

/// An owned client connection and its validated request, handed from the socket thread to @WM.
struct DaemonMessage: Sendable {
  let connection: IPCConnection
  let request: IPCRequest
}

enum MessageLoop {
  static func begin(socketPath: String) -> Bool {
    guard var address = try? IPCConnection.address(socketPath) else { return false }
    let listener = socket(AF_UNIX, SOCK_STREAM, 0)
    guard listener >= 0 else { return false }
    var transferred = false
    defer {
      if !transferred { Darwin.close(listener) }
    }
    let flags = fcntl(listener, F_GETFD)
    guard flags >= 0, fcntl(listener, F_SETFD, flags | FD_CLOEXEC) == 0 else { return false }
    unlink(socketPath)
    let bound = withUnsafePointer(to: &address) {
      $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
        bind(listener, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
      }
    }
    guard bound == 0 else { return false }
    guard chmod(socketPath, 0o600) == 0, listen(listener, SOMAXCONN) == 0 else {
      unlink(socketPath)
      return false
    }
    transferred = true
    Thread.detachNewThread { run(listener) }
    return true
  }

  private static func run(_ listener: Int32) -> Never {
    while true {
      let fd = accept(listener, nil, nil)
      guard fd >= 0 else { continue }
      guard let connection = try? IPCConnection(taking: fd) else { continue }
      receiveClient(connection) { EventLoop.post(.daemonMessage($0)) }
    }
  }

  /// Reads only one frame. The caller transfers the connection to the event loop or the rejection writer.
  static func receiveClient(_ connection: IPCConnection, handler: (DaemonMessage) -> Void) {
    do {
      guard let payload = try connection.readFrame(limit: IPCProtocol.requestLimit, timeout: 1)
      else { throw IPCError.incomplete }
      let request = try IPCProtocol.decode(IPCRequest.self, payload: payload)
      handler(DaemonMessage(connection: connection, request: request))
    } catch {
      Logger.ipc.warning("message rejected: \(error)")
      responses.async {
        do {
          try write(.error(command: nil, message: "\(error)\n"), to: connection)
          try write(.complete(ok: false), to: connection)
        } catch { Logger.ipc.debug("rejection write failed: \(error)") }
      }
    }
  }

  /// Commands stay synchronous on @WM; only value snapshots cross to a writer queue.
  @WM static func handle(_ message: DaemonMessage) {
    Logger.ipc.debug("request: \(String(describing: message.request))")
    let results = executeRequest(message.request)
    if results.count == 1, case .subscribe(let types) = results[0].response.disposition {
      do {
        let firstFrame = try IPCProtocol.encode(
          IPCReply.subscribed(events: types.map(\.name)), limit: IPCProtocol.responseLimit)
        EventSubscribers.shared.add(
          connection: message.connection, types: Set(types), firstFrame: firstFrame)
      } catch {
        var response = Response()
        response.fail(CommandError("could not encode subscription\n"))
        send([CommandResponse(command: 1, response: response)], to: message.connection)
      }
      return
    }
    send(results, to: message.connection)
  }

  // NOTE: A stalled client never writes on @WM. Queued work retains its socket until its final write.
  private static let responses = DispatchSerialQueue(label: "yabai.ipc")

  private static func write(_ reply: IPCReply, to connection: IPCConnection) throws(IPCError) {
    try connection.write(
      IPCProtocol.encode(reply, limit: IPCProtocol.responseLimit), timeout: 1)
  }

  private static func send(_ results: [CommandResponse], to connection: IPCConnection) {
    responses.async {
      var failed = false
      do {
        for result in results {
          for entry in result.response.entries {
            if case .error = entry { failed = true }
            let bytes: [UInt8]
            do {
              bytes = try IPCProtocol.encode(
                IPCOutput(command: result.command, entry: entry),
                limit: IPCProtocol.responseLimit)
            } catch {
              failed = true
              try write(.error(command: result.command, message: "\(error)\n"), to: connection)
              continue
            }
            try connection.write(bytes, timeout: 1)
          }
        }
        try write(.complete(ok: !failed), to: connection)
      } catch { Logger.ipc.debug("response write failed: \(error)") }
    }
  }
}
