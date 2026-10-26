import OrderedCollections
import Synchronization
import Testing
import YabaiCore

@testable import Yabai

//
// NOTE: Swift Testing runs tests in parallel. The tests that change or read the global managers (the state of the
// daemon) are nested in this suite, which runs them one at a time. The daemonFixture trait resets that state before
// every test, so no test depends on what an earlier one (e.g. the golden replay) left behind.
//

@Suite(.serialized, .daemonFixture)
struct DaemonState {}

/// Resets the global managers to the state of a daemon without displays, spaces or windows before each test, and turns
/// on headless mode (never off again), so that flushes and payload messages are recorded instead of reaching the
/// window server or Dock.
struct DaemonFixture: SuiteTrait, TestTrait, TestScoping {
  var isRecursive: Bool { true }

  func provideScope(
    for test: Test, testCase: Test.Case?, performing function: @Sendable () async throws -> Void
  ) async throws {
    await Self.reset()
    try await function()
  }

  @WM static func reset() {
    Headless.enable()
    Headless.displayFrame = Headless.defaultDisplayFrame
    Headless.activeSpace = nil
    Config.current.resetToDefaults()
    DisplayManager.shared.invalidateSpaceCaches()
    Log.verbose.store(false, ordering: .relaxed)
    MouseState.shared.tap.modifier = Config.current.mouse.modifier
    MouseState.shared.tap.dragSplit.store(Config.current.mouse.dragSplit, ordering: .relaxed)
    MouseState.shared.tap.splitDragActive = false
    MouseState.shared.splitDrag = nil
    MouseState.shared.currentAction = .none
    MouseState.shared.window = nil
    MouseState.shared.ffmWindowID = nil
    MouseState.shared.ffmRecheck = FFMRecheck()
    SplitDragCache.reset()
    WindowManager.shared.initialize()
    WindowManager.shared.rules = []
    WindowManager.shared.scratchpads = [:]
    WindowManager.shared.labels = LabelList<WindowID>()
    WindowManager.shared.focus.focusChanged(to: nil)
    WindowManager.shared.focus.clearPending()
    WindowManager.shared.focus.setLast(nil)
    WindowManager.shared.animationsSuppressed = false
    Config.current.applySpaceDefaults()
    SpaceManager.shared.resetViews()
    EventSignals.shared.table = SignalTable()
    EventSignals.shared.discardPending()
    EventSubscribers.shared.removeAll()
    ConfigLoader.shared.reset()
    // NOTE: The printed defaults are taken now, as the startup settings step takes them, before any test changes an option.
    _ = ConfigLoader.shared.defaultWords()
  }
}

extension Trait where Self == DaemonFixture {
  /// Resets the daemon state before each test of the suite.
  static var daemonFixture: Self { DaemonFixture() }
}
