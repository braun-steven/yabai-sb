import Darwin
import Dispatch
import Logging
import Synchronization
import YabaiCore

//
// NOTE: The event subscribers (`yabai -m subscribe`). A subscriber is a socket that receives the events of its types
// (all of them when it names none) as JSON lines (eventJSONLine). EventSignals.flush publishes each pushed event on @WM.
// The publish encodes the line once, and queues it on the private serial queue of each matching subscriber. No write runs
// on @WM, so a client that does not read cannot block the event loop.
//
// NOTE: A write to a client that does not read blocks in the kernel once the socket buffer is full. @WM counts the bytes
// queued and not yet written per subscriber (the backlog). A line that would pass the backlog limit (1 MiB) ends the
// subscriber instead of queueing it. Ending shuts the socket down, which wakes a blocked write; the queued writes then
// fail at once and skip. SO_SNDTIMEO is the second bound: a write that stalls for sendTimeout seconds fails and ends the
// subscriber the same way.
//
// NOTE: An fd is closed only on the subscriber's queue, after its last queued write, and only by the call that ends the
// subscriber (the first exchange of its ended flag). A fd number is therefore never reused while a write may use it.
// The subscriber is removed from the list on @WM through EventLoop.post(.eventSubscriberRemoved), since the write that
// ends it runs off @WM.
//
// NOTE: The daemon ignores SIGPIPE (Yabai.swift installSignalHandlers). Each subscriber socket also sets SO_NOSIGPIPE, so a
// write to a closed peer fails with EPIPE on whatever thread writes.
//
// NOTE: The app and title filters of `signal --add` do not apply to event subscribers: a subscriber has no command to
// run, so it gets every pushed event of its types, with the environment values of the event.
//

/// A client that receives the events of its types as JSON lines. Its writes run on its own serial queue.
final class EventSubscriber: Sendable {
  let id: Int
  /// The socket of the client. The subscriber owns it and closes it when it ends.
  let fd: Int32
  /// The event types, all of them when empty.
  let types: Set<SignalType>

  private let queue: DispatchSerialQueue
  /// The bytes queued and not yet written. Added on @WM and subtracted on the queue.
  private let backlog = Atomic<Int>(0)
  /// Set once, by the call that ends the subscriber (see end()).
  private let ended = Atomic<Bool>(false)

  init(id: Int, fd: Int32, types: Set<SignalType>) {
    self.id = id
    self.fd = fd
    self.types = types
    queue = DispatchSerialQueue(label: "yabai.events.subscriber.\(id)")
  }

  var isEnded: Bool { ended.load(ordering: .acquiring) }

  func matches(_ type: SignalType) -> Bool {
    types.isEmpty || types.contains(type)
  }

  /// Queues a line for the client, or ends the subscriber when its backlog would pass the limit. Called on @WM.
  func enqueue(_ line: [UInt8], backlogLimit: Int) {
    guard !isEnded else { return }

    guard backlog.load(ordering: .relaxed) + line.count <= backlogLimit else {
      Logger.ipc.warning(
        "event subscriber \(id) ended: more than \(backlogLimit) bytes of events are waiting for it"
      )
      end()
      return
    }

    _ = backlog.add(line.count, ordering: .relaxed)
    queue.async { self.write(line) }
  }

  /// Writes one queued line. Runs on the queue; the write waits while the client does not read.
  private func write(_ line: [UInt8]) {
    defer { _ = backlog.subtract(line.count, ordering: .relaxed) }
    guard !isEnded else { return }

    var written = 0
    while written < line.count {
      let result = line.withUnsafeBytes {
        Darwin.write(fd, $0.baseAddress! + written, line.count - written)
      }
      if result < 0 && errno == EINTR { continue }
      if result <= 0 {
        // NOTE: A closed peer (EPIPE) or a stalled client (EAGAIN after SO_SNDTIMEO) is normal, so this is a debug line.
        let code = errno
        Logger.ipc.debug("event subscriber \(id) ended: write failed with errno \(code)")
        end()
        return
      }
      written += result
    }
  }

  /// Ends the subscriber once, from any thread. The socket is shut down, so a write waiting on the client returns; the
  /// fd is closed on the queue after the queued writes; and @WM is asked to remove the subscriber.
  func end() {
    guard !ended.exchange(true, ordering: .acquiringAndReleasing) else { return }

    Darwin.shutdown(fd, SHUT_RDWR)
    queue.async { Darwin.close(self.fd) }
    EventLoop.post(.eventSubscriberRemoved(id: id))
  }
}

/// The subscribers of the events. Runs on @WM.
@WM final class EventSubscribers {
  static let shared = EventSubscribers()

  /// The most bytes a subscriber may have queued and not yet written. The tests pass a smaller limit to init.
  let backlogLimit: Int

  /// The subscribers, in the order they were added. An ended subscriber stays here until its removal event is handled.
  private(set) var subscribers: [EventSubscriber] = []
  private var nextID = 1

  init(backlogLimit: Int = 1 << 20) {
    self.backlogLimit = backlogLimit
  }

  /// Whether a subscriber that has not ended wants the events of this type. EventSignals.push records the events that do.
  func wants(_ type: SignalType) -> Bool {
    subscribers.contains { $0.matches(type) && !$0.isEnded }
  }

  /// Adds a socket as a subscriber to the events of the types (all events when empty). The subscriber takes the fd, and
  /// closes it when it ends. Returns the id of the subscriber.
  @discardableResult
  func add(fd: Int32, types: Set<SignalType>) -> Int {
    //
    // NOTE: SO_NOSIGPIPE and SO_SNDTIMEO (5 s) are set on the socket, as on the response sockets of the message loop.
    // The timeout is only a bound for a stalled client; the backlog limit is what ends a client that falls behind.
    //
    var one: Int32 = 1
    setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
    var timeout = timeval(tv_sec: 5, tv_usec: 0)
    setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))

    let id = nextID
    nextID += 1
    subscribers.append(EventSubscriber(id: id, fd: fd, types: types))
    return id
  }

  /// Publishes a pushed event to the subscribers of its type. The line is encoded once; no write runs on @WM.
  func publish(_ type: SignalType, arguments: [(name: String, value: String)]) {
    guard wants(type) else { return }

    let line = eventJSONLine(type: type.name, arguments: arguments)
    guard !line.isEmpty else { return }

    for subscriber in subscribers where subscriber.matches(type) {
      subscriber.enqueue(line, backlogLimit: backlogLimit)
    }
  }

  /// Ends (a no-op when it already ended) and removes a subscriber. Handles .eventSubscriberRemoved, which an ended
  /// subscriber posts.
  func remove(_ id: Int) {
    for subscriber in subscribers where subscriber.id == id { subscriber.end() }
    subscribers.removeAll { $0.id == id }
  }

  /// Ends and removes every subscriber, for the tests that reset the registry.
  func removeAll() {
    for subscriber in subscribers { subscriber.end() }
    subscribers.removeAll()
  }
}
