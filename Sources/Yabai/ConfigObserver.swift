import Observation
import YabaiCore

//
// NOTE: Borders, tab bars, window opacity, the menu bar alpha and shadows follow Config through Observation. Each
// group is tracked on its own; the first set of it posts one configChanged event, also when the value is equal, so
// re-running a config re-applies it as the config setters did. The handler runs after the event that set the config (a
// whole config message, for example) and before the next event: it tracks the group again and applies it. Several
// sets of one message apply once, and the window server gets them in event order.
//

/// The parts of Config that a renderer applies.
enum ConfigGroup: CaseIterable, Sendable {
  case border
  case tabBar
  case opacity
  case windowOpacity
  case menuBar
  case shadow
}

/// Follows Config for the renderers.
@WM final class ConfigObserver {
  static let shared = ConfigObserver()

  /// The tab bar config last applied, to choose between rebuilding and redrawing the bars.
  private var tabBar = TabBarConfig()

  /// Starts following Config; call once, at startup.
  func start() {
    tabBar = Config.current.tabBar
    for group in ConfigGroup.allCases { track(group) }
  }

  /// Applies a group of Config that was set.
  func apply(_ group: ConfigGroup) {
    track(group)
    let wm = WindowManager.shared
    switch group {
    case .border:
      Border.refreshAll()
    case .tabBar:
      let old = tabBar
      tabBar = Config.current.tabBar
      TabBar.applyConfig(tabBar, from: old)
    case .opacity:
      wm.applyOpacityEnabled()
    case .windowOpacity:
      wm.applyWindowOpacity()
    case .menuBar:
      SLS.setMenuBarAlpha(SLS.connection, Config.current.menuBar.opacity)
    case .shadow:
      wm.applyShadows()
    }
  }

  /// Reads the group, so that Observation tracks it.
  static func read(_ group: ConfigGroup) {
    let config = Config.current
    switch group {
    case .border: _ = config.border
    case .tabBar: _ = config.tabBar
    case .opacity: _ = config.opacity
    case .windowOpacity: _ = config.windowOpacity
    case .menuBar: _ = config.menuBar
    case .shadow: _ = config.shadow
    }
  }

  /// Tracks a group; its next set posts configChanged.
  private func track(_ group: ConfigGroup) {
    withObservationTracking {
      Self.read(group)
    } onChange: {
      EventLoop.post(.configChanged(group))
    }
  }
}
