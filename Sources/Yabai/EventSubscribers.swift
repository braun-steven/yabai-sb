import Darwin
import Dispatch
import Logging
import Synchronization
import YabaiCore

//
// NOTE: The event subscribers (`yabai -m subscribe`). A subscriber is a socket that receives the events of its types
// (all of them when it names none) as framed events. EventSignals.flush publishes each pushed event on @WM.
// The publish encodes the line once, and queues it on the private serial queue of each matching subscriber. No write runs
// on @WM, so a client that does not read cannot block the event loop.
//
// NOTE: A write to a client that does not read blocks in the kernel once the socket buffer is full. @WM counts the bytes
// queued and not yet written per subscriber (the backlog). A line that would pass the backlog limit (1 MiB) ends the
// subscriber instead of queueing it. Ending shuts the socket down, which wakes a blocked write; the queued writes then
// fail at once and skip. A five-second absolute write deadline provides a second bound.
//
// NOTE: The connection owns its descriptor. Queued writes retain the subscriber, so closing cannot reuse its fd
// under a pending write. Shutdown wakes a stalled writer; removal is posted back to @WM.
//
// NOTE: The app and title filters of `signal --add` do not apply to event subscribers: a subscriber has no command to
// run, so it gets every pushed event of its types, with the environment values of the event.
//

/// A client that receives framed events of its types. Its writes run on its own serial queue.
final class EventSubscriber: Sendable {
  let id: Int
  /// The socket of the client. The subscriber owns it and closes it when it ends.
  private let connection: IPCConnection
  /// The event types, all of them when empty.
  let types: Set<SignalType>

  private let queue: DispatchSerialQueue
  /// The bytes queued and not yet written. Added on @WM and subtracted on the queue.
  private let backlog = Atomic<Int>(0)
  /// Set once, by the call that ends the subscriber (see end()).
  private let ended = Atomic<Bool>(false)

  init(id: Int, connection: IPCConnection, types: Set<SignalType>) {
    self.id = id
    self.connection = connection
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

    do {
      try connection.write(line, timeout: 5)
    } catch {
      Logger.ipc.debug("event subscriber \(id) ended: \(error)")
      end()
    }
  }

  /// Ends the subscriber once, from any thread. The socket is shut down, so a write waiting on the client returns; the
  /// connection closes after its queued writes release it; and @WM is asked to remove the subscriber.
  func end() {
    guard !ended.exchange(true, ordering: .acquiringAndReleasing) else { return }

    connection.shutdown()
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
  /// closes it when it ends. A non-empty firstFrame (the subscribed line) is queued before any event, on the subscriber's
  /// own queue, so it reaches the client first. Returns the id of the subscriber.
  @discardableResult
  func add(connection: IPCConnection, types: Set<SignalType>, firstFrame: [UInt8] = []) -> Int {
    let id = nextID
    nextID += 1
    let subscriber = EventSubscriber(id: id, connection: connection, types: types)
    subscribers.append(subscriber)
    if !firstFrame.isEmpty {
      subscriber.enqueue(firstFrame, backlogLimit: backlogLimit)
    }
    return id
  }

  /// Publishes a pushed event to the subscribers of its type. The line is encoded once; no write runs on @WM.
  func publish(_ type: SignalType, arguments: [(name: String, value: String)]) {
    guard wants(type) else { return }

    guard
      let line = try? IPCProtocol.encode(
        IPCReply.event(data: eventObject(type: type.name, arguments: arguments)),
        limit: IPCProtocol.responseLimit)
    else { return }

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
