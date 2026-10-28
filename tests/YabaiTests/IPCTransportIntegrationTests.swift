import Testing
import YabaiCore

@testable import Yabai

extension DaemonState {
  @Suite @WM struct IPCTransportIntegrationTests {
    @Test func responseQueueClosesItsConnectionAfterCompletion() throws {
      var pair: (server: IPCConnection, client: IPCConnection)? = try ipcPair()
      let client = try #require(pair?.client)
      MessageLoop.handle(
        DaemonMessage(
          connection: try #require(pair?.server),
          request: .command(arguments: ["config", "debug_output"])))
      pair = nil
      #expect(try readReply(client) == .output(command: 1, data: .string("off\n"), format: .text))
      #expect(try readReply(client) == .complete(ok: true))
      #expect(try client.readFrame(limit: IPCProtocol.responseLimit, timeout: 30) == nil)
    }

    @Test func requestPassesThroughFramingDispatchAndResponseWrite() throws {
      let (server, client) = try ipcPair()
      let request = IPCRequest.command(arguments: ["unknown_test_domain"])
      try client.write(IPCProtocol.encode(request, limit: IPCProtocol.requestLimit), timeout: 30)
      client.finishRequest()
      var received: IPCRequest?
      MessageLoop.receiveClient(server) { message in
        received = message.request
        MessageLoop.handle(message)
      }
      #expect(received == request)
      #expect(
        try readReply(client)
          == .error(command: 1, message: "unknown domain 'unknown_test_domain'\n"))
      #expect(try readReply(client) == .complete(ok: false))
    }

    @Test func malformedBatchIsRejectedBeforeExecutingAnyCommand() throws {
      let (server, client) = try ipcPair()
      let payload = Array(#"{"type":"batch","commands":[["config","window_gap","99"],[]]}"#.utf8)
      try client.write(IPCProtocol.header(length: payload.count) + payload, timeout: 30)
      client.finishRequest()
      var called = false
      MessageLoop.receiveClient(server) { _ in called = true }
      #expect(!called)
      #expect(try readReply(client) == .error(command: nil, message: "invalid IPC message\n"))
      #expect(try readReply(client) == .complete(ok: false))
      #expect(Golden.run("config window_gap") == Array("0\n".utf8))
    }

    @Test func mixedBatchRepliesHaveStructuredResultsAndOverallFailure() throws {
      let (server, client) = try ipcPair()
      MessageLoop.handle(
        DaemonMessage(
          connection: server,
          request: .batch(commands: [
            ["config", "window_gap", "bad"], ["config", "debug_output"],
          ])))
      guard case .error(let index, let message) = try readReply(client) else {
        Issue.record("expected a structured error")
        return
      }
      #expect(index == 1)
      #expect(message.hasPrefix("unknown value 'bad'"))
      #expect(try readReply(client) == .output(command: 2, data: .string("off\n"), format: .text))
      #expect(try readReply(client) == .complete(ok: false))
    }
  }
}
