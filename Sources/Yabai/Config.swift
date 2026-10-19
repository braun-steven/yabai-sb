import Observation
import YabaiCore

//
// NOTE: Each renderer action has its own property (border, tabBar, opacity, windowOpacity, menuBar, shadow), since
// Observation tracks Config's properties, not their fields. A set through a field notifies even with an equal value,
// so re-running a config applies it again; assigning a whole equal struct does not notify.
//

/// The settings of the config domain. `Config.current` starts with the defaults of a new daemon; the space layout
/// default becomes tree in `SpaceManager.begin`. It is observable, so that renderers follow its changes; runtime state
/// that only lasts for an operation stays out of it.
@WM @Observable final class Config
{
    static let current = Config()

    var border = BorderConfig()
    var tabBar = TabBarConfig()
    var window = WindowConfig()
    var opacity = OpacityConfig()
    var windowOpacity = WindowOpacityConfig()
    var menuBar = MenuBarConfig()
    var shadow = ShadowConfig()
    var mouse = MouseConfig()
    var animation = AnimationConfig()
    var scratchpad = ScratchpadConfig()
    var space = SpaceDefaults()
    var display = DisplayConfig()

    /// Restores the defaults of a new daemon.
    func resetToDefaults()
    {
        let defaults = Config()
        border = defaults.border
        tabBar = defaults.tabBar
        window = defaults.window
        opacity = defaults.opacity
        windowOpacity = defaults.windowOpacity
        menuBar = defaults.menuBar
        shadow = defaults.shadow
        mouse = defaults.mouse
        animation = defaults.animation
        scratchpad = defaults.scratchpad
        space = defaults.space
        display = defaults.display
    }
}

struct SpaceDefaults
{
    var layout = ViewType.default
    var topPadding: Int = 0
    var bottomPadding: Int = 0
    var leftPadding: Int = 0
    var rightPadding: Int = 0
    var windowGap: Int = 0
    var autoPadding = false
    var treeDefaultOrientation = TreeOrientation.auto
    var treeWorkspaceTabbed = false
    var treeAutotiling = false
    var skipWindowFocusAnimation = false
    var spaceLayouts: [SpaceLayout] = []
    var spaceLayoutSpec: String?
}

struct DisplayConfig
{
    var order = DisplayArrangementOrder.default
    var builtinDisplayLast = false
    var externalBar = ExternalBarConfig()
}

/// The space an external status bar reserves (`config external_bar`).
struct ExternalBarConfig
{
    var mode = ExternalBarMode.off
    var topPadding: Int = 0
    var bottomPadding: Int = 0
}

struct WindowConfig: Equatable
{
    var mouseFollowsFocus = false
    var focusFollowsMouse = FocusFollowsMouse.disabled
    var origin = WindowOrigin.default
    var opacityDuration: Float = 0.0
    var insertionFeedbackColor = RGBAColor(hex: 0xffd75f5f)
    var focusWrapping = FocusWrapping.on
}

/// Whether yabai sets window opacity (`window_opacity`).
struct OpacityConfig: Equatable
{
    var enabled = false
}

/// The opacity of the focused and the other windows (`active_window_opacity`, `normal_window_opacity`).
struct WindowOpacityConfig: Equatable
{
    var active: Float = 1.0
    var normal: Float = 1.0
}

/// The menu bar (`menubar_opacity`).
struct MenuBarConfig: Equatable
{
    var opacity: Float = 1.0
}

/// Window shadows (`window_shadow`).
struct ShadowConfig: Equatable
{
    var mode = PurifyMode.disabled
}

/// The mouse actions. `MouseTapState.modifier` mirrors `modifier` for the event tap; both start as fn.
struct MouseConfig
{
    var modifier = MouseModifierKey.fn
    var action1 = MouseAction.move
    var action2 = MouseAction.resize
    var dropAction = MouseAction.swap
}

struct AnimationConfig
{
    var duration: Float = 0.0
    var easing = AnimationEasing.easeOutCirc
}

struct ScratchpadConfig
{
    var exclusive = false
    var raise = false
    var below = false
    var grid = Grid()
}

struct BorderConfig: Equatable
{
    var enabled = false
    var hideSingle = false
    var width: Float = 4.0
    var activeColor = RGBAColor(hex: 0xffe1e3e4)
    var normalColor = RGBAColor(hex: 0xff494d64)
}

struct TabBarConfig: Equatable
{
    var enabled = true
    var height = 24
    var offset = 0
    var icons = true
    var style = TabBarStyle.glass
    var appearance = TabBarAppearance.dark
    var backdrop = TabBarBackdrop.blur
    var cardPadding = 6
    var windowRadius = 16
    var fontName = "system:12"
    var focusedColor = RGBAColor(hex: 0xff285577)
    var focusedTextColor = RGBAColor(hex: 0xffffffff)
    var inactiveColor = RGBAColor(hex: 0xff5f676a)
    var inactiveTextColor = RGBAColor(hex: 0xffffffff)
    var unfocusedColor = RGBAColor(hex: 0xff222222)
    var unfocusedTextColor = RGBAColor(hex: 0xff888888)
    var backdropColor = RGBAColor(hex: 0xff48484a)
    var focusedColorIsCustom = false
    var inactiveColorIsCustom = false
    var unfocusedColorIsCustom = false
    var backdropColorIsCustom = false
    var focusedTextColorIsCustom = false
    var inactiveTextColorIsCustom = false
    var unfocusedTextColorIsCustom = false
}

extension TabBarConfig
{
    /// Whether the change from old changes the window area or the kind of bars: the bars are then rebuilt and the
    /// views laid out again. Other changes only redraw the bars.
    func needsRebuild(from old: TabBarConfig) -> Bool
    {
        enabled != old.enabled || height != old.height || offset != old.offset || cardPadding != old.cardPadding
            || style != old.style || backdrop != old.backdrop
    }
}
