import Testing

@testable import YabaiCore

//
// NOTE: A gate draws the first key, each key that differs from the last one drawn, and nothing else. Reset makes the
// next key draw again, which a renderer needs when it hides its window or the window is destroyed.
//

@Suite("RenderGate")
struct RenderGateTests {
  /// Replays `keys` on a new gate and returns the draw decision of each.
  private func replay(_ keys: [Int]) -> [Bool] {
    var gate = RenderGate<Int>()
    return keys.map { gate.needsDraw($0) }
  }

  @Test func firstKeyIsDrawn() {
    #expect(replay([1]) == [true])
  }

  @Test func repeatedKeyIsDrawnOnce() {
    #expect(replay([1, 1, 1]) == [true, false, false])
  }

  @Test func changedKeyIsDrawnAgain() {
    #expect(replay([1, 2]) == [true, true])
  }

  @Test func returningToAnOlderKeyIsDrawn() {
    #expect(replay([1, 2, 1, 1]) == [true, true, true, false])
  }

  @Test func resetDrawsTheSameKeyAgain() {
    var gate = RenderGate<String>()
    let first = gate.needsDraw("a")
    let repeated = gate.needsDraw("a")
    gate.reset()
    let afterReset = gate.needsDraw("a")
    let repeatedAfterReset = gate.needsDraw("a")
    #expect([first, repeated, afterReset, repeatedAfterReset] == [true, false, true, false])
  }
}
