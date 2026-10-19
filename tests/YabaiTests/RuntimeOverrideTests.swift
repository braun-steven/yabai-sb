import Testing
@testable import Yabai
import YabaiCore

//
// NOTE: Runtime overrides change the managers' state, so the tests are part of DaemonState.
//

extension DaemonState
{
    @Suite
    @WM struct RuntimeOverrideTests
    {
        @Test("an open menu turns focus follows mouse off without changing the config")
        func menuSuspendsFocusFollowsMouse()
        {
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

        @Test("suppressed animations keep the configured duration")
        func withoutAnimationsKeepsDuration()
        {
            let wm = WindowManager.shared
            let configured = Config.current.animation.duration
            defer { Config.current.animation.duration = configured }
            Config.current.animation.duration = 0.25
            wm.withoutAnimations {
                #expect(wm.animationDuration == 0)
                wm.withoutAnimations { #expect(wm.animationDuration == 0) }
                #expect(wm.animationDuration == 0)
                #expect(Config.current.animation.duration == 0.25)
            }
            #expect(wm.animationDuration == 0.25)
        }
    }
}
