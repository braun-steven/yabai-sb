import Observation
import Synchronization
import Testing
@testable import Yabai
import YabaiCore

//
// NOTE: The tests change Config, so they are part of DaemonState. They do not start ConfigObserver, whose updates reach
// the window server.
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

        @Test("a change of a config value is observable")
        func configChangeIsObservable()
        {
            let width = Config.current.border.width
            defer { Config.current.border.width = width }
            let flag = Flag()
            withObservationTracking {
                _ = Config.current.border
            } onChange: {
                flag.isSet.store(true, ordering: .relaxed)
            }
            Config.current.border.width = width + 1
            let isSet = flag.isSet.load(ordering: .relaxed)
            #expect(isSet)
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
