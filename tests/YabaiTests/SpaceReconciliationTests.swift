import Testing
import YabaiCore
import YabaiTestSupport

@testable import Yabai

extension DaemonState {
  @Suite
  @WM struct SpaceReconciliationTests {
    private func sid(_ value: UInt64) -> SpaceID {
      return SpaceID(0xFFFF_1000 + value)
    }

    private func display(
      _ value: UInt32, _ spaces: [SpaceLayoutSpaceState], visible: SpaceID? = nil
    ) -> SpaceLayoutDisplayState {
      return SpaceLayoutDisplayState(did: DisplayID(value), spaces: spaces, visible: visible)
    }

    @Test func layoutMovesOneUnpinnedSpaceFromTheSurplusDisplay() {
      let visible = sid(2)
      let source = display(
        1,
        [
          SpaceLayoutSpaceState(sid: sid(1), isUser: true, isLastUserSpace: false),
          SpaceLayoutSpaceState(sid: visible, isUser: true, isLastUserSpace: false),
          SpaceLayoutSpaceState(sid: sid(3), isUser: true, isLastUserSpace: false),
          SpaceLayoutSpaceState(sid: sid(4), isUser: false, isLastUserSpace: false),
        ], visible: visible)
      let destination = display(
        2, [SpaceLayoutSpaceState(sid: sid(5), isUser: true, isLastUserSpace: true)])

      #expect(
        SpaceLayoutReconciler.nextAction(
          target: [2, 2], displays: [source, destination], pinned: [sid(3)], emptySpaces: [])
          == .move(space: sid(1), from: DisplayID(1), to: DisplayID(2)))
    }

    @Test func layoutCreatesOneSpaceOnTheFirstDeficitDisplay() {
      let displays = [
        display(1, [SpaceLayoutSpaceState(sid: sid(1), isUser: true, isLastUserSpace: true)]),
        display(2, [SpaceLayoutSpaceState(sid: sid(2), isUser: true, isLastUserSpace: true)]),
      ]

      #expect(
        SpaceLayoutReconciler.nextAction(
          target: [1, 2], displays: displays, pinned: [], emptySpaces: [])
          == .create(on: DisplayID(2)))
    }

    @Test func layoutCreatesOnTheDeficitWhenEverySurplusSpaceIsPinned() {
      let source = display(
        1,
        [
          SpaceLayoutSpaceState(sid: sid(1), isUser: true, isLastUserSpace: false),
          SpaceLayoutSpaceState(sid: sid(2), isUser: true, isLastUserSpace: false),
        ], visible: sid(1))
      let destination = display(2, [])

      #expect(
        SpaceLayoutReconciler.nextAction(
          target: [1, 1], displays: [source, destination], pinned: [sid(1), sid(2)],
          emptySpaces: []) == .create(on: DisplayID(2)))
    }

    @Test func layoutDestroysOneEmptyUnpinnedNonvisibleSpace() {
      let visible = sid(1)
      let state = display(
        1,
        [
          SpaceLayoutSpaceState(sid: visible, isUser: true, isLastUserSpace: false),
          SpaceLayoutSpaceState(sid: sid(2), isUser: true, isLastUserSpace: false),
          SpaceLayoutSpaceState(sid: sid(3), isUser: true, isLastUserSpace: false),
          SpaceLayoutSpaceState(sid: sid(4), isUser: false, isLastUserSpace: false),
        ], visible: visible)

      #expect(
        SpaceLayoutReconciler.nextAction(
          target: [1], displays: [state], pinned: [sid(2)], emptySpaces: [sid(1), sid(2), sid(3)])
          == .destroy(space: sid(3), on: DisplayID(1)))
    }

    @Test func layoutKeepsNonemptySpacesAndOnlyUsesVisibleAsAFallback() {
      let visible = sid(1)
      let state = display(
        1,
        [
          SpaceLayoutSpaceState(sid: visible, isUser: true, isLastUserSpace: false),
          SpaceLayoutSpaceState(sid: sid(2), isUser: true, isLastUserSpace: false),
        ], visible: visible)

      #expect(
        SpaceLayoutReconciler.nextAction(
          target: [1], displays: [state], pinned: [], emptySpaces: [visible])
          == .destroy(space: visible, on: DisplayID(1)))
      #expect(
        SpaceLayoutReconciler.nextAction(
          target: [1], displays: [state], pinned: [], emptySpaces: []) == .done)
    }

    @Test func layoutKeepsTheLastUserSpace() {
      let onlySpace = sid(1)
      let state = display(
        1,
        [SpaceLayoutSpaceState(sid: onlySpace, isUser: true, isLastUserSpace: true)],
        visible: onlySpace)

      #expect(SpaceLayoutReconciler.destroyCandidateOrder(on: state, pinned: []).isEmpty)
      #expect(
        SpaceLayoutReconciler.nextAction(
          target: [1], displays: [state], pinned: [], emptySpaces: [onlySpace]) == .done)
    }

    @Test func pinReconcileSkipsLastUserSpacesAndMovesTheNextPin() {
      let last = SpacePinMove(sid: sid(1), did: DisplayID(2))
      let movable = SpacePinMove(sid: sid(2), did: DisplayID(1))
      let candidates = [
        SpacePinMoveState(move: last, isLastUserSpace: true),
        SpacePinMoveState(move: movable, isLastUserSpace: false),
      ]

      #expect(
        SpacePinReconciler.nextMove(candidates: candidates) == movable)
      #expect(SpacePinReconciler.nextMove(candidates: Array(candidates.prefix(1))) == nil)
    }
  }
}
