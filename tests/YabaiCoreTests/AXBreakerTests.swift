import Darwin
import Testing

@testable import YabaiCore

@Suite("AXBreaker")
struct AXBreakerTests {
  private let start = ContinuousClock.now
  private let frozen: pid_t = 4242
  private let other: pid_t = 4243

  @Test func closedByDefault() {
    let breaker = AXBreaker()
    #expect(!breaker.isOpen(pid: frozen, now: start))
  }

  @Test func timeoutOpensOnlyItsPid() {
    var breaker = AXBreaker()
    #expect(breaker.recordTimeout(pid: frozen, now: start) == .opened)
    #expect(breaker.isOpen(pid: frozen, now: start))
    #expect(!breaker.isOpen(pid: other, now: start))
  }

  // The breaker is open for [start, start + cooldown).
  @Test(arguments: [
    (Duration.zero, true),
    (.milliseconds(1), true),
    (.milliseconds(1999), true),
    (.seconds(2), false),
    (.seconds(30), false),
  ])
  func openForTheCooldown(elapsed: Duration, expectedOpen: Bool) {
    var breaker = AXBreaker()
    breaker.recordTimeout(pid: frozen, now: start)
    #expect(breaker.isOpen(pid: frozen, now: start.advanced(by: elapsed)) == expectedOpen)
  }

  @Test func timeoutWhileOpenExtendsWithoutTransition() {
    var breaker = AXBreaker()
    breaker.recordTimeout(pid: frozen, now: start)
    let later = start.advanced(by: .seconds(1))
    #expect(breaker.recordTimeout(pid: frozen, now: later) == nil)
    #expect(breaker.isOpen(pid: frozen, now: start.advanced(by: .seconds(2))))
    #expect(!breaker.isOpen(pid: frozen, now: later.advanced(by: AXBreaker.cooldown)))
  }

  @Test func successClosesTheBreaker() {
    var breaker = AXBreaker()
    breaker.recordTimeout(pid: frozen, now: start)
    #expect(breaker.recordSuccess(pid: frozen) == .closed)
    #expect(!breaker.isOpen(pid: frozen, now: start))
  }

  @Test func successWithoutEntryIsSilent() {
    var breaker = AXBreaker()
    #expect(breaker.recordSuccess(pid: frozen) == nil)
    breaker.recordTimeout(pid: other, now: start)
    #expect(breaker.recordSuccess(pid: frozen) == nil)
    #expect(breaker.isOpen(pid: other, now: start))
  }

  @Test func successAfterCooldownClearsTheExpiredEntry() {
    var breaker = AXBreaker()
    breaker.recordTimeout(pid: frozen, now: start)
    let expired = start.advanced(by: AXBreaker.cooldown)
    #expect(!breaker.isOpen(pid: frozen, now: expired))
    #expect(breaker.recordSuccess(pid: frozen) == .closed)
    #expect(breaker.recordSuccess(pid: frozen) == nil)
  }

  @Test func timeoutAfterCooldownOpensAgain() {
    var breaker = AXBreaker()
    breaker.recordTimeout(pid: frozen, now: start)
    let expired = start.advanced(by: AXBreaker.cooldown)
    #expect(breaker.recordTimeout(pid: frozen, now: expired) == .opened)
    #expect(breaker.isOpen(pid: frozen, now: expired))
  }
}
