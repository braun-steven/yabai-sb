import Testing
@testable import YabaiCore

@Suite("Cached")
struct CachedTests
{
    private let start = ContinuousClock.now

    @Test func emptyUntilStored()
    {
        let cache = Cached<Int>(lifetime: .seconds(2))
        #expect(cache.value(at: start) == nil)
    }

    @Test func returnsTheStoredValueUntilInvalidated()
    {
        var cache = Cached<Int>(lifetime: .seconds(2))
        cache.store(7, at: start)

        #expect(cache.value(at: start) == 7)
        #expect(cache.value(at: start.advanced(by: .milliseconds(1500))) == 7)

        cache.invalidate()
        #expect(cache.value(at: start) == nil)
    }

    // The value is fresh for [start, start + lifetime).
    @Test(arguments: [
        (Duration.zero, true),
        (.milliseconds(1999), true),
        (.seconds(2), false),
        (.seconds(30), false),
    ])
    func expiresAfterTheLifetime(elapsed: Duration, expectedFresh: Bool)
    {
        var cache = Cached<String>(lifetime: .seconds(2))
        cache.store("a", at: start)

        #expect((cache.value(at: start.advanced(by: elapsed)) != nil) == expectedFresh)
    }

    @Test func storeReplacesTheValueAndRestartsTheLifetime()
    {
        var cache = Cached<Int>(lifetime: .seconds(2))
        cache.store(1, at: start)
        cache.store(2, at: start.advanced(by: .seconds(1)))

        #expect(cache.value(at: start.advanced(by: .milliseconds(2500))) == 2)
        #expect(cache.value(at: start.advanced(by: .seconds(3))) == nil)
    }

    @Test func invalidateOnEmptyIsHarmless()
    {
        var cache = Cached<Int>(lifetime: .seconds(2))
        cache.invalidate()
        #expect(cache.value(at: start) == nil)

        cache.store(3, at: start)
        #expect(cache.value(at: start) == 3)
    }
}
