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
        handler.openMenus = [:]
      }
      handler.openMenus = [:]
      Config.current.window.focusFollowsMouse = .autofocus
      handler.menuOpened(pid: 1)
      handler.menuOpened(pid: 1)
      #expect(handler.focusFollowsMouse == .disabled)
      #expect(Config.current.window.focusFollowsMouse == .autofocus)
      handler.menuClosed(pid: 1)
      #expect(handler.focusFollowsMouse == .disabled)
      handler.menuClosed(pid: 1)
      #expect(handler.focusFollowsMouse == .autofocus)
      handler.menuClosed(pid: 1)
      #expect(handler.openMenus.isEmpty)
    }

    @Test("a close of another application does not close a menu")
    func menusAreCountedPerApplication() {
      let handler = EventHandler.shared
      defer { handler.openMenus = [:] }
      handler.openMenus = [:]
      handler.menuOpened(pid: 1)
      handler.menuClosed(pid: 2)
      #expect(handler.openMenus == [1: 1])
    }

    @Test("setting the mode recovers from a menu that never reported its close")
    func settingTheModeClearsOpenMenus() {
      let handler = EventHandler.shared
      let configured = Config.current.window.focusFollowsMouse
      defer {
        WindowManager.shared.setFocusFollowsMouse(configured)
        handler.openMenus = [:]
      }
      handler.menuOpened(pid: 1)
      WindowManager.shared.setFocusFollowsMouse(.autofocus)
      #expect(handler.focusFollowsMouse == .autofocus)
    }
  }
}
