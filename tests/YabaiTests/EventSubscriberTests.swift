import Darwin
import Foundation
import Testing
import YabaiCore
import YabaiTestSupport

@testable import Yabai

//
// NOTE: The subscribers run on socketpairs: the registry takes one end and the test reads the other. The registry tests
// use their own EventSubscribers instances, so they do not touch the shared managers. Every wait is bounded (a receive
// timeout or a deadline), so a missing write fails the test instead of hanging it.
//

/// A socketpair for a subscriber: the subscriber takes the first end, the test reads the second, whose reads time out.
private func subscriberSocketPair() throws -> (subscriber: Int32, peer: Int32) {
  var pair: [Int32] = [0, 0]
  try #require(socketpair(AF_UNIX, SOCK_STREAM, 0, &pair) == 0)

  var timeout = timeval(tv_sec: 5, tv_usec: 0)
  setsockopt(pair[1], SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
  return (pair[0], pair[1])
}

/// Reads up to count bytes from the peer; fewer when the read fails or times out, or the subscriber closed its end.
private func receive(_ fd: Int32, count: Int) -> [UInt8] {
  var bytes: [UInt8] = []
  var chunk = [UInt8](repeating: 0, count: 4096)
  while bytes.count < count {
    let read = chunk.withUnsafeMutableBytes {
      Darwin.read(fd, $0.baseAddress!, min($0.count, count - bytes.count))
    }
    if read <= 0 { break }
    bytes += chunk[..<read]
  }
  return bytes
}

/// Polls a condition until it holds or the deadline passes, and returns whether it held.
private func waitUntil(seconds: Int = 10, _ condition: () -> Bool) -> Bool {
  let deadline = ContinuousClock.now + .seconds(seconds)
  while !condition() {
    if ContinuousClock.now > deadline { return false }
    usleep(1_000)
  }
  return true
}

@Suite struct EventSubscriberTests {
  @Test @WM func publishWritesOneLinePerEventInOrder() throws {
    let (fd, peer) = try subscriberSocketPair()
    defer { close(peer) }

    let subscribers = EventSubscribers(backlogLimit: 1 << 20)
    subscribers.add(fd: fd, types: [])

    var expected = ""
    for index in 0..<50 {
      subscribers.publish(
        .windowFocused, arguments: [("YABAI_WINDOW_ID", "\(index)"), ("YABAI_PROCESS_ID", "7")])
      expected += "{\"event\":\"window_focused\",\"process_id\":\"7\",\"window_id\":\"\(index)\"}\n"
    }

    #expect(receive(peer, count: expected.utf8.count) == Array(expected.utf8))
    subscribers.removeAll()
  }

  @Test @WM func subscriberReceivesOnlyItsTypes() throws {
    let (spaceFD, spacePeer) = try subscriberSocketPair()
    let (allFD, allPeer) = try subscriberSocketPair()
    defer {
      close(spacePeer)
      close(allPeer)
    }

    let subscribers = EventSubscribers(backlogLimit: 1 << 20)
    subscribers.add(fd: spaceFD, types: [.spaceChanged])
    subscribers.add(fd: allFD, types: [])

    subscribers.publish(.windowFocused, arguments: [("YABAI_WINDOW_ID", "42")])
    subscribers.publish(.spaceChanged, arguments: [("YABAI_SPACE_ID", "9")])

    let spaceLine = "{\"event\":\"space_changed\",\"space_id\":\"9\"}\n"
    let windowLine = "{\"event\":\"window_focused\",\"window_id\":\"42\"}\n"
    #expect(receive(spacePeer, count: spaceLine.utf8.count) == Array(spaceLine.utf8))
    #expect(
      receive(allPeer, count: windowLine.utf8.count + spaceLine.utf8.count)
        == Array((windowLine + spaceLine).utf8))
    subscribers.removeAll()
  }

  /// A client whose peer closed gets EPIPE, not SIGPIPE: the subscriber ends and the registry removes it.
  @Test @WM func closedPeerEndsAndIsRemoved() throws {
    let (fd, peer) = try subscriberSocketPair()
    let subscribers = EventSubscribers(backlogLimit: 1 << 20)
    let id = subscribers.add(fd: fd, types: [])
    close(peer)

    subscribers.publish(.windowFocused, arguments: [("YABAI_WINDOW_ID", "42")])
    #expect(waitUntil { subscribers.subscribers.first { $0.id == id }?.isEnded == true })
    #expect(!subscribers.wants(.windowFocused))

    subscribers.remove(id)
    #expect(subscribers.subscribers.isEmpty)
  }

  /// A client that never reads: once its backlog passes the limit, the subscriber is ended without @WM waiting for the
  /// write, the socket is shut down (the blocked write returns), and the fd is closed after the queued writes, so the
  /// peer sees the bytes that were written and then the end of the stream.
  @Test @WM func nonReadingSubscriberIsEndedAtBacklogLimit() throws {
    let (fd, peer) = try subscriberSocketPair()
    defer { close(peer) }

    let subscribers = EventSubscribers(backlogLimit: 4096)
    let id = subscribers.add(fd: fd, types: [])
    let subscriber = subscribers.subscribers.first { $0.id == id }

    var published = 0
    while published < 200_000, subscriber?.isEnded == false {
      subscribers.publish(
        .windowFocused,
        arguments: [("YABAI_WINDOW_ID", "\(published)"), ("YABAI_PROCESS_ID", "123456789")])
      published += 1
    }
    #expect(subscriber?.isEnded == true)
    #expect(published < 200_000)

    var reachedEnd = false
    var chunk = [UInt8](repeating: 0, count: 65536)
    while true {
      let read = chunk.withUnsafeMutableBytes { Darwin.read(peer, $0.baseAddress!, $0.count) }
      if read == 0 {
        reachedEnd = true
        break
      }
      if read < 0 { break }
    }
    #expect(reachedEnd)

    subscribers.remove(id)
  }
}

// NOTE: The pushed events reach the shared registry through EventSignals.flush, so these tests run in the DaemonState suite.
extension DaemonState {
  @Suite struct EventSubscriberSignals {
    @Test @WM func pushedEventsReachSubscribersOnFlush() throws {
      let (fd, peer) = try subscriberSocketPair()
      defer { close(peer) }

      let id = EventSubscribers.shared.add(fd: fd, types: [.spaceDestroyed])
      defer { EventSubscribers.shared.remove(id) }

      // NOTE: No subscriber wants displayRemoved, so its push records nothing.
      EventSignals.shared.push(.displayRemoved, .display(DisplayID(0xFFFF_0000)))
      #expect(EventSignals.shared.pending.isEmpty)

      EventSignals.shared.push(.spaceDestroyed, .space(SpaceID(0xFFFF_0000)))
      #expect(EventSignals.shared.pending.count == 1)
      EventSignals.shared.flush()
      #expect(EventSignals.shared.pending.isEmpty)

      let expected =
        "{\"event\":\"space_destroyed\",\"space_id\":\"\(Int64(bitPattern: 0xFFFF_0000))\"}\n"
      #expect(receive(peer, count: expected.utf8.count) == Array(expected.utf8))
    }
  }
}
