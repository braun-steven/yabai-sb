import Testing
import YabaiCore
import YabaiTestSupport

@testable import Yabai

extension DaemonState {
  @Suite @WM struct SubscribeTests {
    @Test func subscriptionAcknowledgementPrecedesPushedEvents() throws {
      let (server, client) = try ipcPair()
      defer { EventSubscribers.shared.removeAll() }
      MessageLoop.handle(
        DaemonMessage(
          connection: server, request: .command(arguments: ["subscribe", "space_destroyed"])))
      #expect(EventSubscribers.shared.subscribers.count == 1)
      EventSignals.shared.push(.spaceDestroyed(SpaceID(0xFFFF_0000)))
      EventSignals.shared.flush()
      #expect(try readReply(client) == .subscribed(events: ["space_destroyed"]))
      #expect(
        try readReply(client)
          == .event(data: [
            "event": "space_destroyed", "space_id": "\(Int64(bitPattern: 0xFFFF_0000))",
          ]))
    }

    @Test func unknownEventIsACompletedFailure() throws {
      let (server, client) = try ipcPair()
      MessageLoop.handle(
        DaemonMessage(
          connection: server, request: .command(arguments: ["subscribe", "not_an_event"])))
      guard case .error(let index, let message) = try readReply(client) else {
        Issue.record("expected a subscription error")
        return
      }
      #expect(index == 1)
      #expect(message.hasPrefix("unknown event 'not_an_event'"))
      #expect(try readReply(client) == .complete(ok: false))
      #expect(EventSubscribers.shared.subscribers.isEmpty)
    }
  }
}
