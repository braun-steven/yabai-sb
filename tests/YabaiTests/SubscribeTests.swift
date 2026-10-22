import Darwin
import Testing
import YabaiCore
import YabaiTestSupport

@testable import Yabai

//
// NOTE: `yabai -m subscribe` through the message loop, on a socketpair: the daemon takes one end as the client's socket,
// the test reads the other. Every read is bounded (receive times out after 5 s), so a missing line fails the test
// instead of hanging it. The registry is cleared after each test that subscribes.
//

/// The message the daemon reads for these words, as readMessage gives it: the payload with the two padding nulls.
private func daemonBytes(_ words: [String]) -> [UInt8] {
  Array(ClientMessage.encode(words.map { Array($0.utf8) }).dropFirst(MemoryLayout<Int32>.size))
    + [0, 0]
}

extension DaemonState {
  @Suite
  @WM struct SubscribeTests {
    //
    // NOTE: The first line is queued before the event is published, and the events are pushed before the test reads
    // anything: the lines must still arrive in that order, since the subscriber's queue keeps it.
    //
    @Test func subscribedLineComesFirstThenThePushedEvent() throws {
      let (fd, peer) = try subscriberSocketPair()
      defer { close(peer) }
      defer { EventSubscribers.shared.removeAll() }

      MessageLoop.handle(
        DaemonMessage(sockfd: fd, bytes: daemonBytes(["subscribe", "space_destroyed"])))
      #expect(EventSubscribers.shared.subscribers.count == 1)

      EventSignals.shared.push(.spaceDestroyed, .space(SpaceID(0xFFFF_0000)))
      EventSignals.shared.flush()

      let subscribed = "{\"subscribed\":[\"space_destroyed\"]}\n"
      let event =
        "{\"event\":\"space_destroyed\",\"space_id\":\"\(Int64(bitPattern: 0xFFFF_0000))\"}\n"
      #expect(
        receive(peer, count: subscribed.utf8.count + event.utf8.count)
          == Array((subscribed + event).utf8))
    }

    //
    // NOTE: An unknown event is a normal failure: one failure byte and its text, then the socket is closed (the read
    // below ends at the end of the stream), and nothing is subscribed.
    //
    @Test func unknownEventFailsAndClosesTheSocket() throws {
      let (fd, peer) = try subscriberSocketPair()
      defer { close(peer) }

      MessageLoop.handle(
        DaemonMessage(sockfd: fd, bytes: daemonBytes(["subscribe", "not_an_event"])))

      let response = receive(peer, count: 4096)
      #expect(response.first == Response.failureByte)
      #expect(
        String(decoding: response.dropFirst(), as: UTF8.self).hasPrefix(
          "unknown event 'not_an_event' for domain 'subscribe'; expected one of: application_launched, "
        ))
      #expect(EventSubscribers.shared.subscribers.isEmpty)
    }

    //
    // NOTE: A batch response cannot become a stream, so a subscribe inside a batch fails at its own index and subscribes
    // nothing. The batch is the only response that reaches the client, as one failure.
    //
    @Test func subscribeInsideABatchIsRefused() {
      var response = Response()
      var message = Message(
        Array(
          ClientMessage.encode(BatchMessage.encode([["subscribe", "window_focused"]])).dropFirst(
            MemoryLayout<Int32>.size)) + [0, 0])
      handleMessage(&response, &message)

      #expect(
        String(decoding: response.bytes, as: UTF8.self)
          == "\u{07}1: batch: subscribe keeps its client connected and cannot run in a batch\n")
      #expect(response.subscribedTypes == nil)
      #expect(EventSubscribers.shared.subscribers.isEmpty)
    }
  }
}
