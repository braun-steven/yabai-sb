import Observation
import YabaiCore

//
// NOTE: Borders, tab bars, window opacity, the menu bar alpha and shadows follow Config through Observation. The first
// change after Config was tracked posts one configChanged event. Its handler runs after the event that changed the
// config (a whole config message, for example) and before the next event: it tracks Config again and hands each
// renderer the values that differ from the ones it applied last. Several changes of one message apply together, and
// the window server gets them in event order. The renderers start with the defaults applied, so start() changes
// nothing.
//

/// Follows Config for the renderers.
@WM final class ConfigObserver
{
    static let shared = ConfigObserver()

    private var border = BorderConfig()
    private var tabBar = TabBarConfig()
    private var window = WindowConfig()

    /// Starts following Config; call once, at startup.
    func start()
    {
        border = Config.current.border
        tabBar = Config.current.tabBar
        window = Config.current.window
        track()
    }

    /// Applies the config changes since the last call to the renderers.
    func apply()
    {
        track()
        let config = Config.current
        if config.border != border {
            border = config.border
            Border.refreshAll()
        }
        if config.tabBar != tabBar {
            let old = tabBar
            tabBar = config.tabBar
            TabBar.applyConfig(tabBar, from: old)
        }
        if config.window != window {
            let old = window
            window = config.window
            WindowManager.shared.applyWindowConfig(window, from: old)
        }
    }

    /// Tracks the config the renderers show; its next change posts configChanged.
    private func track()
    {
        withObservationTracking {
            _ = Config.current.border
            _ = Config.current.tabBar
            _ = Config.current.window
        } onChange: {
            EventLoop.post(.configChanged)
        }
    }
}
