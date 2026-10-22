//
// NOTE: A value kept for a lifetime, read through an explicit instant, so that its expiry needs neither the window
// server nor a sleeping test. The owner invalidates it when it changes what the value describes, or when it learns of
// such a change; the lifetime is the safety net for a change that no one reported.
//

/// A value that stays fresh until it is invalidated or its lifetime has passed.
public struct Cached<Value>
{
    /// How long a stored value stays fresh.
    public let lifetime: ContinuousClock.Duration

    private var entry: (value: Value, storedAt: ContinuousClock.Instant)?

    public init(lifetime: ContinuousClock.Duration)
    {
        self.lifetime = lifetime
    }

    /// The stored value while it is fresh at `now`; nil when nothing is stored, it expired or it was invalidated.
    public func value(at now: ContinuousClock.Instant) -> Value?
    {
        guard let entry else { return nil }
        return now < entry.storedAt.advanced(by: lifetime) ? entry.value : nil
    }

    /// Stores a value, fresh from `now` on. It replaces the stored one.
    public mutating func store(_ value: Value, at now: ContinuousClock.Instant)
    {
        entry = (value, now)
    }

    /// Drops the stored value, so that the next read computes it again.
    public mutating func invalidate()
    {
        entry = nil
    }
}

//
// NOTE: Sendable when the value is. A manager that is @WM but has a nonisolated shared instance (DisplayManager) needs its
// stored defaults to be Sendable, so a Cached of a non-Sendable value cannot be a stored property there.
//
extension Cached: Sendable where Value: Sendable {}
