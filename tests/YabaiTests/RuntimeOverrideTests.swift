import Testing
import YabaiCore
import YabaiTestSupport

@testable import Yabai

//
// NOTE: Runtime overrides change the managers' state, so the tests are part of DaemonState.
//

extension DaemonState {
  @Suite
  @WM struct RuntimeOverrideTests {
    @Test("an open menu turns focus follows mouse off without changing the config")
    func menuSuspendsFocusFollowsMouse() {
      let handler = EventHandler.shared
      let configured = Config.current.window.focusFollowsMouse
      defer {
        Config.current.window.focusFollowsMouse = configured
        handler.openMenuCount = 0
      }
      handler.openMenuCount = 0
      Config.current.window.focusFollowsMouse = .autofocus
      handler.menuOpened()
      handler.menuOpened()
      #expect(handler.focusFollowsMouse == .disabled)
      #expect(Config.current.window.focusFollowsMouse == .autofocus)
      handler.menuClosed()
      #expect(handler.focusFollowsMouse == .disabled)
      handler.menuClosed()
      #expect(handler.focusFollowsMouse == .autofocus)
      handler.menuClosed()
      #expect(handler.openMenuCount == 0)
    }
  }
}
