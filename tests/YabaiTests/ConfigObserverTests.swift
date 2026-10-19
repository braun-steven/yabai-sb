import Observation
import Synchronization
import Testing
@testable import Yabai
import YabaiCore

//
// NOTE: The tests set Config to its current values, so they change nothing, but they are part of DaemonState. They do
// not start ConfigObserver, whose updates reach the window server.
//

extension DaemonState
{
    @Suite
    @WM struct ConfigObserverTests
    {
        final class Flag: Sendable
        {
            let isSet = Atomic(false)
        }

        @Test("a config set notifies its group, also with an equal value")
        func equalSetNotifies()
        {
            let flag = Flag()
            withObservationTracking {
                ConfigObserver.read(.menuBar)
            } onChange: {
                flag.isSet.store(true, ordering: .relaxed)
            }
            Config.current.menuBar.opacity = Config.current.menuBar.opacity
            let isSet = flag.isSet.load(ordering: .relaxed)
            #expect(isSet)
        }

        @Test("a config set notifies only its own group")
        func setNotifiesOnlyItsGroup()
        {
            let flag = Flag()
            withObservationTracking {
                ConfigObserver.read(.windowOpacity)
            } onChange: {
                flag.isSet.store(true, ordering: .relaxed)
            }
            Config.current.window.mouseFollowsFocus = Config.current.window.mouseFollowsFocus
            Config.current.opacity.enabled = Config.current.opacity.enabled
            let isSet = flag.isSet.load(ordering: .relaxed)
            #expect(!isSet)
        }

        @Test("every group is tracked")
        func everyGroupNotifies()
        {
            for group in ConfigGroup.allCases {
                let flag = Flag()
                withObservationTracking {
                    ConfigObserver.read(group)
                } onChange: {
                    flag.isSet.store(true, ordering: .relaxed)
                }
                switch group {
                case .border:        Config.current.border.width = Config.current.border.width
                case .tabBar:        Config.current.tabBar.height = Config.current.tabBar.height
                case .opacity:       Config.current.opacity.enabled = Config.current.opacity.enabled
                case .windowOpacity: Config.current.windowOpacity.active = Config.current.windowOpacity.active
                case .menuBar:       Config.current.menuBar.opacity = Config.current.menuBar.opacity
                case .shadow:        Config.current.shadow.mode = Config.current.shadow.mode
                }
                let isSet = flag.isSet.load(ordering: .relaxed)
                #expect(isSet, "\(group)")
            }
        }

        @Test("tab bar changes of the window area rebuild the bars, others redraw them")
        func tabBarRebuild()
        {
            let old = TabBarConfig()
            var config = old
            config.height += 1
            #expect(config.needsRebuild(from: old))
            config = old
            config.style = old.style == .glass ? .i3 : .glass
            #expect(config.needsRebuild(from: old))
            config = old
            config.icons.toggle()
            config.windowRadius += 1
            config.fontName = "system:13"
            #expect(!config.needsRebuild(from: old))
        }
    }
}
