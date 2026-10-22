import Algorithms
import DequeModule

//
// NOTE: The pending delayed events of EventLoop, in deadline order. Pure: the caller passes the current instant, so
// the tests don't sleep. An insert goes after the events with the same or an earlier deadline, so equal deadlines
// keep their posting order (two deferred focus activations must not swap). An insert with a key first removes the
// pending event with that key, so a newer schedule supersedes an older one; unkeyed events are never superseded.
//
// NOTE: A keyed event that is delivered (removeDue) but not yet handled is in flight until claim(key:) runs on the
// handler. The event stream is FIFO, so the handler sees the in-flight events in delivery order. An insert with a
// key marks every event of that key in flight as stale, and the stale ones are dropped when they are claimed: a
// schedule supersedes an event that is already in the stream too. cancel(key:) does the same without a new element.
//

struct DelayedQueue<Element: Sendable, Key: Hashable & Sendable>: Sendable
{
    private struct Entry: Sendable
    {
        let deadline: ContinuousClock.Instant
        let key: Key?
        let element: Element
    }

    private var entries: Deque<Entry> = []
    /// The keyed events delivered and not yet claimed, per key.
    private var inFlight: [Key: Int] = [:]
    /// How many of the in-flight events of a key are superseded. They are the oldest ones, since the stream is FIFO.
    private var stale: [Key: Int] = [:]

    var isEmpty: Bool
    {
        entries.isEmpty
    }

    /// The earliest deadline of the pending events, nil when none is pending.
    var nextDeadline: ContinuousClock.Instant?
    {
        entries.first?.deadline
    }

    /// Adds an element due at the deadline. A key removes the pending element with the same key first, and marks the
    /// in-flight elements with that key as stale.
    mutating func insert(_ element: Element, at deadline: ContinuousClock.Instant, key: Key? = nil)
    {
        if let key {
            entries.removeAll { $0.key == key }
            stale[key] = inFlight[key]
        }

        let index = entries.partitioningIndex { $0.deadline > deadline }
        entries.insert(Entry(deadline: deadline, key: key, element: element), at: index)
    }

    /// Removes the pending element with this key and marks the in-flight elements with that key as stale, as an insert
    /// with the key does, but adds no element.
    mutating func cancel(key: Key)
    {
        entries.removeAll { $0.key == key }
        stale[key] = inFlight[key]
    }

    /// Removes and returns the elements whose deadline is not after `now`, in deadline order, each with its key. A
    /// keyed element is in flight until `claim(key:)` runs for it.
    mutating func removeDue(at now: ContinuousClock.Instant) -> [(element: Element, key: Key?)]
    {
        let count = entries.partitioningIndex { $0.deadline > now }
        let due = entries.prefix(count).map { (element: $0.element, key: $0.key) }
        entries.removeFirst(count)

        for case let key? in due.map(\.key) { inFlight[key, default: 0] += 1 }
        return due
    }

    /// Called when the handler takes a delivered element with this key. Returns false when the element was superseded
    /// after its delivery, so the handler must drop it.
    mutating func claim(key: Key) -> Bool
    {
        guard let delivered = inFlight[key] else { return true }
        inFlight[key] = delivered > 1 ? delivered - 1 : nil

        guard let superseded = stale[key] else { return true }
        stale[key] = superseded > 1 ? superseded - 1 : nil
        return false
    }
}
