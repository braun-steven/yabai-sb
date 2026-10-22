import Testing
@testable import Yabai

//
// NOTE: The ordering of delayed events, and the superseding of keyed events, pinned on the pure DelayedQueue. The
// instants are offsets from one origin read once per test, so nothing sleeps.
//

@Suite struct DelayedQueueTests
{
    private let origin = ContinuousClock.now

    private func at(_ milliseconds: Int) -> ContinuousClock.Instant
    {
        origin.advanced(by: .milliseconds(milliseconds))
    }

    private func elements(_ due: [(element: String, key: String?)]) -> [String]
    {
        due.map(\.element)
    }

    @Test func emptyQueueHasNoDeadlineAndNothingIsDue()
    {
        var queue = DelayedQueue<String, String>()
        #expect(queue.isEmpty)
        #expect(queue.nextDeadline == nil)
        #expect(queue.removeDue(at: at(1000)).isEmpty)
    }

    @Test func deliversInDeadlineOrderWhateverTheInsertOrder()
    {
        var queue = DelayedQueue<String, String>()
        queue.insert("c", at: at(300))
        queue.insert("a", at: at(100))
        queue.insert("b", at: at(200))

        #expect(queue.nextDeadline == at(100))
        #expect(elements(queue.removeDue(at: at(1000))) == ["a", "b", "c"])
        #expect(queue.isEmpty)
    }

    @Test func equalDeadlinesKeepPostingOrder()
    {
        var queue = DelayedQueue<String, String>()
        queue.insert("first", at: at(100))
        queue.insert("second", at: at(100))
        queue.insert("third", at: at(100))
        queue.insert("early", at: at(50))

        #expect(elements(queue.removeDue(at: at(100))) == ["early", "first", "second", "third"])
    }

    @Test func deliversOnlyDueElementsAndOnce()
    {
        var queue = DelayedQueue<String, String>()
        queue.insert("a", at: at(100))
        queue.insert("b", at: at(200))
        queue.insert("c", at: at(300))

        #expect(queue.removeDue(at: at(99)).isEmpty)
        #expect(elements(queue.removeDue(at: at(100))) == ["a"])
        #expect(queue.nextDeadline == at(200))
        #expect(elements(queue.removeDue(at: at(250))) == ["b"])
        #expect(queue.removeDue(at: at(250)).isEmpty)
        #expect(elements(queue.removeDue(at: at(300))) == ["c"])
        #expect(queue.nextDeadline == nil)
    }

    @Test func earlierInsertBecomesTheNextDeadline()
    {
        var queue = DelayedQueue<String, String>()
        queue.insert("late", at: at(500))
        #expect(queue.nextDeadline == at(500))

        queue.insert("early", at: at(100))
        #expect(queue.nextDeadline == at(100))
    }

    @Test func keyedInsertReplacesThePendingElementWithTheSameKey()
    {
        var queue = DelayedQueue<String, String>()
        queue.insert("old", at: at(300), key: "reconcile")
        queue.insert("new", at: at(100), key: "reconcile")

        #expect(queue.nextDeadline == at(100))
        #expect(elements(queue.removeDue(at: at(1000))) == ["new"])
    }

    @Test func keyedInsertKeepsElementsWithOtherKeysAndUnkeyedOnes()
    {
        var queue = DelayedQueue<String, String>()
        queue.insert("plain", at: at(100))
        queue.insert("other", at: at(150), key: "focus")
        queue.insert("keyed-old", at: at(200), key: "reconcile")
        queue.insert("keyed-new", at: at(300), key: "reconcile")

        #expect(elements(queue.removeDue(at: at(1000))) == ["plain", "other", "keyed-new"])
    }

    @Test func unkeyedInsertsAreNeverSuperseded()
    {
        var queue = DelayedQueue<String, String>()
        queue.insert("x", at: at(100))
        queue.insert("x", at: at(100))

        #expect(elements(queue.removeDue(at: at(100))) == ["x", "x"])
    }

    @Test func replacementPostsAfterElementsWithTheSameDeadline()
    {
        var queue = DelayedQueue<String, String>()
        queue.insert("k-old", at: at(50), key: "k")
        queue.insert("a", at: at(100))
        queue.insert("b", at: at(100))
        queue.insert("k-new", at: at(100), key: "k")

        #expect(elements(queue.removeDue(at: at(100))) == ["a", "b", "k-new"])
    }

    @Test func keyIsFreeAgainOnceItsElementIsDelivered()
    {
        var queue = DelayedQueue<String, String>()
        queue.insert("first", at: at(100), key: "k")
        #expect(elements(queue.removeDue(at: at(100))) == ["first"])

        queue.insert("second", at: at(200), key: "k")
        #expect(elements(queue.removeDue(at: at(200))) == ["second"])
    }

    @Test func removeDueReturnsTheKeyOfEachElement()
    {
        var queue = DelayedQueue<String, String>()
        queue.insert("plain", at: at(100))
        queue.insert("keyed", at: at(200), key: "k")

        #expect(queue.removeDue(at: at(1000)).map(\.key) == [nil, "k"])
    }

    // MARK: Superseding an event that is already delivered

    @Test func supersededDeliveredEventIsDroppedWhenClaimed()
    {
        var queue = DelayedQueue<String, String>()
        queue.insert("a1", at: at(100), key: "k")
        #expect(elements(queue.removeDue(at: at(100))) == ["a1"])

        queue.insert("b", at: at(300), key: "k")
        #expect(queue.claim(key: "k") == false)

        #expect(elements(queue.removeDue(at: at(300))) == ["b"])
        #expect(queue.claim(key: "k") == true)
    }

    @Test func deliveredEventIsHandledWhenNothingSupersedesIt()
    {
        var queue = DelayedQueue<String, String>()
        queue.insert("a", at: at(100), key: "k")
        #expect(elements(queue.removeDue(at: at(100))) == ["a"])

        #expect(queue.claim(key: "k") == true)
    }

    @Test func twoSchedulesWhileTheEventIsInFlightDropItOnce()
    {
        var queue = DelayedQueue<String, String>()
        queue.insert("a", at: at(100), key: "k")
        #expect(elements(queue.removeDue(at: at(100))) == ["a"])

        queue.insert("b", at: at(200), key: "k")
        queue.insert("c", at: at(300), key: "k")
        #expect(elements(queue.removeDue(at: at(300))) == ["c"])

        #expect(queue.claim(key: "k") == false)
        #expect(queue.claim(key: "k") == true)
    }

    @Test func supersedingMarksEveryInFlightEventOfTheKey()
    {
        var queue = DelayedQueue<String, String>()
        queue.insert("a", at: at(100), key: "k")
        #expect(elements(queue.removeDue(at: at(100))) == ["a"])
        queue.insert("b", at: at(200), key: "k")
        #expect(elements(queue.removeDue(at: at(200))) == ["b"])

        queue.insert("c", at: at(300), key: "k")
        #expect(elements(queue.removeDue(at: at(300))) == ["c"])

        #expect(queue.claim(key: "k") == false)
        #expect(queue.claim(key: "k") == false)
        #expect(queue.claim(key: "k") == true)
    }

    @Test func eventDeliveredAfterTheSupersedeIsNotStale()
    {
        var queue = DelayedQueue<String, String>()
        queue.insert("a", at: at(100), key: "k")
        #expect(elements(queue.removeDue(at: at(100))) == ["a"])
        queue.insert("b", at: at(200), key: "k")
        #expect(queue.claim(key: "k") == false)

        queue.insert("c", at: at(300), key: "k")
        #expect(elements(queue.removeDue(at: at(300))) == ["c"])
        #expect(queue.claim(key: "k") == true)
    }

    @Test func unkeyedEventsDoNotCountAsInFlightOrSupersedeAnything()
    {
        var queue = DelayedQueue<String, String>()
        queue.insert("plain", at: at(100))
        #expect(elements(queue.removeDue(at: at(100))) == ["plain"])

        queue.insert("keyed", at: at(200), key: "k")
        queue.insert("plain", at: at(250))
        #expect(queue.claim(key: "k") == true)
        #expect(elements(queue.removeDue(at: at(300))) == ["keyed", "plain"])
    }

    @Test func keysSupersedeIndependently()
    {
        var queue = DelayedQueue<String, String>()
        queue.insert("a", at: at(100), key: "k1")
        #expect(elements(queue.removeDue(at: at(100))) == ["a"])

        queue.insert("x", at: at(200), key: "k2")
        #expect(queue.claim(key: "k1") == true)
        #expect(queue.claim(key: "k2") == true)
    }

    @Test func claimWithNothingInFlightIsTrue()
    {
        var queue = DelayedQueue<String, String>()
        #expect(queue.claim(key: "k") == true)

        queue.insert("pending", at: at(100), key: "k")
        #expect(queue.claim(key: "k") == true)
    }
}
