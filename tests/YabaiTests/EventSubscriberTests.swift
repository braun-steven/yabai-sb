import Darwin
import Dispatch
import Foundation
import Synchronization
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
func subscriberSocketPair() throws -> (subscriber: Int32, peer: Int32) {
  var pair: [Int32] = [0, 0]
  try #require(socketpair(AF_UNIX, SOCK_STREAM, 0, &pair) == 0)

  var timeout = timeval(tv_sec: 5, tv_usec: 0)
  setsockopt(pair[1], SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
  return (pair[0], pair[1])
}

/// Reads up to count bytes from the peer; fewer when the read fails or times out, or the subscriber closed its end.
func receive(_ fd: Int32, count: Int) -> [UInt8] {
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

/// Decodes framed events, retaining the content assertions used for event publication.
private func receiveEvents(_ fd: Int32, count: Int) -> [UInt8] {
  do {
    let connection = try IPCConnection(taking: dup(fd))
    var output: [UInt8] = []
    while output.count < count {
      guard case .event(let object) = try readReply(connection) else {
        Issue.record("expected event frame")
        return output
      }
      output += try JSON.encode(object) + [UInt8(ascii: "\n")]
    }
    return output
  } catch {
    Issue.record("cannot receive event: \(error)")
    return []
  }
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

private final class SubscriberEndRecorder: Sendable {
  private let storage = Mutex<[Int]>([])
  var ids: [Int] { storage.withLock { $0 } }
  func record(_ id: Int) { storage.withLock { $0.append(id) } }
}

@Suite struct EventSubscriberTests {
  @Test @WM func publishWritesOneLinePerEventInOrder() throws {
    let (fd, peer) = try subscriberSocketPair()
    defer { close(peer) }

    let subscribers = EventSubscribers(onEnded: { _ in })
    subscribers.add(connection: try IPCConnection(taking: fd), types: [])

    var expected = ""
    for index in 0..<50 {
      subscribers.publish(
        .windowFocused, arguments: [("YABAI_WINDOW_ID", "\(index)"), ("YABAI_PROCESS_ID", "7")])
      expected += "{\"event\":\"window_focused\",\"process_id\":\"7\",\"window_id\":\"\(index)\"}\n"
    }

    #expect(receiveEvents(peer, count: expected.utf8.count) == Array(expected.utf8))
    subscribers.removeAll()
  }

  @Test @WM func subscriberReceivesOnlyItsTypes() throws {
    let (spaceFD, spacePeer) = try subscriberSocketPair()
    let (allFD, allPeer) = try subscriberSocketPair()
    defer {
      close(spacePeer)
      close(allPeer)
    }

    let subscribers = EventSubscribers(onEnded: { _ in })
    subscribers.add(connection: try IPCConnection(taking: spaceFD), types: [.spaceChanged])
    subscribers.add(connection: try IPCConnection(taking: allFD), types: [])

    subscribers.publish(.windowFocused, arguments: [("YABAI_WINDOW_ID", "42")])
    subscribers.publish(.spaceChanged, arguments: [("YABAI_SPACE_ID", "9")])

    let spaceLine = "{\"event\":\"space_changed\",\"space_id\":\"9\"}\n"
    let windowLine = "{\"event\":\"window_focused\",\"window_id\":\"42\"}\n"
    #expect(receiveEvents(spacePeer, count: spaceLine.utf8.count) == Array(spaceLine.utf8))
    #expect(
      receiveEvents(allPeer, count: windowLine.utf8.count + spaceLine.utf8.count)
        == Array((windowLine + spaceLine).utf8))
    subscribers.removeAll()
  }

  /// A client whose peer closed gets EPIPE, not SIGPIPE: the subscriber ends and the registry removes it.
  @Test @WM func closedPeerEndsAndIsRemoved() throws {
    let (fd, peer) = try subscriberSocketPair()
    let recorder = SubscriberEndRecorder()
    let subscribers = EventSubscribers(onEnded: { recorder.record($0) })
    let id = subscribers.add(connection: try IPCConnection(taking: fd), types: [])
    close(peer)

    // NOTE: A parallel test's posix_spawn holds a copy of every descriptor until its exec closes them, so a first write
    // can still reach the closed peer (disconnectedPeerCannotRaiseSIGPIPE). Publishes every 100 ms until a write fails.
    var polls = 0
    #expect(
      waitUntil {
        if polls % 100 == 0 {
          subscribers.publish(.windowFocused, arguments: [("YABAI_WINDOW_ID", "42")])
        }
        polls += 1
        return subscribers.subscribers.first { $0.id == id }?.isEnded == true
      })
    #expect(!subscribers.wants(.windowFocused))
    #expect(waitUntil { recorder.ids == [id] })

    subscribers.remove(id)
    #expect(subscribers.subscribers.isEmpty)
    #expect(recorder.ids == [id])
  }

  /// A client that never reads: once its backlog passes the limit, the subscriber is ended without @WM waiting for the
  /// write, the socket is shut down (the blocked write returns), and the fd is closed after the queued writes, so the
  /// peer sees the bytes that were written and then the end of the stream.
  @Test @WM func nonReadingSubscriberIsEndedAtBacklogLimit() throws {
    let (fd, peer) = try subscriberSocketPair()
    defer { close(peer) }

    let recorder = SubscriberEndRecorder()
    let subscribers = EventSubscribers(backlogLimit: 4096, onEnded: { recorder.record($0) })
    let id = subscribers.add(connection: try IPCConnection(taking: fd), types: [])
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
    #expect(waitUntil { recorder.ids == [id] })
  }

  @Test @WM func concurrentEndNotifiesOnlyItsOwningRegistryOnce() throws {
    let (firstFD, firstPeer) = try subscriberSocketPair()
    let (secondFD, secondPeer) = try subscriberSocketPair()
    defer {
      close(firstPeer)
      close(secondPeer)
    }
    let firstRecorder = SubscriberEndRecorder()
    let secondRecorder = SubscriberEndRecorder()
    let first = EventSubscribers(onEnded: { firstRecorder.record($0) })
    let second = EventSubscribers(onEnded: { secondRecorder.record($0) })
    defer {
      first.removeAll()
      second.removeAll()
    }
    let firstID = first.add(connection: try IPCConnection(taking: firstFD), types: [])
    let secondID = second.add(connection: try IPCConnection(taking: secondFD), types: [])
    #expect(firstID == secondID)
    let subscriber = try #require(first.subscribers.first)
    DispatchQueue.concurrentPerform(iterations: 32) { _ in subscriber.end() }
    #expect(firstRecorder.ids == [firstID])
    #expect(secondRecorder.ids.isEmpty)
    #expect(!first.wants(.windowFocused))
    #expect(second.wants(.windowFocused))
    first.remove(firstID)
    #expect(firstRecorder.ids == [firstID])
    second.remove(secondID)
    #expect(secondRecorder.ids == [secondID])
  }
}

// NOTE: The pushed events reach the shared registry through EventSignals.flush, so these tests run in the DaemonState suite.
extension DaemonState {
  @Suite struct EventSubscriberSignals {
    @Test @WM func pushedEventsReachSubscribersOnFlush() throws {
      let (fd, peer) = try subscriberSocketPair()
      defer { close(peer) }

      let id = EventSubscribers.shared.add(
        connection: try IPCConnection(taking: fd), types: [.spaceDestroyed])
      defer { EventSubscribers.shared.remove(id) }

      // NOTE: No subscriber wants displayRemoved, so its push records nothing.
      EventSignals.shared.push(.displayRemoved(DisplayID(0xFFFF_0000)))
      #expect(EventSignals.shared.pending.isEmpty)

      EventSignals.shared.push(.spaceDestroyed(SpaceID(0xFFFF_0000)))
      #expect(EventSignals.shared.pending.count == 1)
      EventSignals.shared.flush()
      #expect(EventSignals.shared.pending.isEmpty)

      let expected =
        "{\"event\":\"space_destroyed\",\"space_id\":\"\(Int64(bitPattern: 0xFFFF_0000))\"}\n"
      #expect(receiveEvents(peer, count: expected.utf8.count) == Array(expected.utf8))
    }
  }
}
