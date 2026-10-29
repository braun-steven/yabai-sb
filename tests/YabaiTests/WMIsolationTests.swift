import Testing
import YabaiTestSupport

@testable import Yabai

//
// NOTE: `WM.assumeIsolated` traps off the yabai.wm queue: that trap is its contract, so the exit test checks it in a
// child process. The child runs only the body of the exit test, not the daemon.
//

@Suite struct WMIsolationTests {
  @Test func assumeIsolatedTrapsOffTheQueue() async {
    await #expect(processExitsWith: .failure) {
      _ = WM.assumeIsolated { 1 }
    }
  }

  /// WM.sync waits for the yabai.wm queue, which an @WM test running in parallel can hold, so it runs on a thread.
  @Test func assumeIsolatedRunsOnTheQueue() async {
    #expect(await onThread { WM.sync { WM.assumeIsolated { 42 } } } == 42)
  }

  @Test @WM func assumeIsolatedRunsInAnIsolatedTest() {
    #expect(WM.assumeIsolated { 7 } == 7)
  }
}
