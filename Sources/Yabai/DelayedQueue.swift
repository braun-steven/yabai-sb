import DequeModule

//
// NOTE: The pending delayed events of EventLoop, in deadline order. Pure: the caller passes the current instant, so
// the tests don't sleep. An insert goes after the events with the same or an earlier deadline, so equal deadlines
// keep their posting order (two deferred focus activations must not swap). An insert with a key first removes the
// pending event with that key, so a newer schedule supersedes an older one; unkeyed events are never superseded.
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

    var isEmpty: Bool
    {
        entries.isEmpty
    }

    /// The earliest deadline of the pending events, nil when none is pending.
    var nextDeadline: ContinuousClock.Instant?
    {
        entries.first?.deadline
    }

    /// Adds an element due at the deadline. A key removes the pending element with the same key first.
    mutating func insert(_ element: Element, at deadline: ContinuousClock.Instant, key: Key? = nil)
    {
        if let key { entries.removeAll { $0.key == key } }

        let index = entries.partitioningIndex { $0.deadline > deadline }
        entries.insert(Entry(deadline: deadline, key: key, element: element), at: index)
    }

    /// Removes and returns the elements whose deadline is not after `now`, in deadline order.
    mutating func removeDue(at now: ContinuousClock.Instant) -> [Element]
    {
        let count = entries.partitioningIndex { $0.deadline > now }
        let due = entries.prefix(count).map(\.element)
        entries.removeFirst(count)
        return due
    }
}
