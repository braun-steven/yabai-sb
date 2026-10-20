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
struct DaemonFixture: SuiteTrait, TestTrait, TestScoping
{
    var isRecursive: Bool { true }

    func provideScope(for test: Test, testCase: Test.Case?, performing function: @Sendable () async throws -> Void) async throws
    {
        await Self.reset()
        try await function()
    }

    @WM static func reset()
    {
        Headless.enable()
        Config.current.resetToDefaults()
        WindowManager.shared.initialize()
        WindowManager.shared.rules = []
        WindowManager.shared.scratchpads = [:]
        WindowManager.shared.focusedWindowID = nil
        WindowManager.shared.pendingFocusWindowID = nil
        WindowManager.shared.lastWindowID = nil
        WindowManager.shared.animationsSuppressed = false
        SpaceManager.shared.resetToDefaults()
        EventSignals.shared.table = SignalTable()
    }
}

extension Trait where Self == DaemonFixture
{
    /// Resets the daemon state before each test of the suite.
    static var daemonFixture: Self { DaemonFixture() }
}
