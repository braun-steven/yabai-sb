import Testing

@testable import YabaiCore

//
// NOTE: The steps of a resize drag: the first frame opens the EUI scope, the frames after it change nothing, and the
// end (a drag end or a cancellation) closes it. Each row replays the events and checks the steps of every event.
//

@Suite("EUIDragScope")
struct EUIDragScopeTests {
  enum DragEvent {
    case begin(enabled: Bool)
    case frame
    case end
  }

  /// Replays `events` on a new scope; a frame returns no step, and checks that the scope is open.
  private func replay(_ events: [DragEvent]) -> [[EUIStep]] {
    var scope = EUIDragScope()
    return events.map { event in
      switch event {
      case .begin(let enabled):
        return scope.begin(enabled: enabled)
      case .frame:
        #expect(scope.isOpen)
        return []
      case .end:
        return scope.end()
      }
    }
  }

  @Test func closedByDefault() {
    let scope = EUIDragScope()
    #expect(!scope.isOpen)
  }

  @Test func dragTurnsEUIOffOnceAndRestoresItAtTheEnd() {
    #expect(
      replay([.begin(enabled: true), .frame, .frame, .end])
        == [[.disable], [], [], [.restore]])
  }

  @Test func dragOfAnApplicationWithEUIOffChangesNothing() {
    #expect(replay([.begin(enabled: false), .frame, .end]) == [[], [], []])
  }

  @Test func cancelledDragWithoutFramesStillRestoresEUI() {
    #expect(replay([.begin(enabled: true), .end]) == [[.disable], [.restore]])
  }

  @Test func secondBeginWhileOpenKeepsTheFirstObservation() {
    // The value read at the second begin (already off, because the drag turned it off) must not be restored later.
    #expect(
      replay([.begin(enabled: true), .begin(enabled: false), .frame, .end])
        == [[.disable], [], [], [.restore]])
  }

  @Test func endWithoutAnOpenScopeDoesNothing() {
    #expect(replay([.end, .begin(enabled: true), .end, .end]) == [[], [.disable], [.restore], []])
  }

  @Test func eachDragGetsItsOwnScope() {
    #expect(
      replay([.begin(enabled: true), .frame, .end, .begin(enabled: true), .frame, .end])
        == [[.disable], [], [.restore], [.disable], [], [.restore]])
  }

  @Test func isOpenFollowsBeginAndEnd() {
    var scope = EUIDragScope()
    scope.begin(enabled: true)
    #expect(scope.isOpen)
    scope.end()
    #expect(!scope.isOpen)
  }
}
