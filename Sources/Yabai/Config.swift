import YabaiCore

@WM struct Config
{
    static var current = Config()

    var border = BorderConfig()
    var tabBar = TabBarConfig()
    var window = WindowConfig()
    var mouse = MouseConfig()
    var animation = AnimationConfig()
    var scratchpad = ScratchpadConfig()
    var space = SpaceDefaults()
    var display = DisplayConfig()
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

struct WindowConfig
{
    var mouseFollowsFocus = false
    var focusFollowsMouse = FocusFollowsMouse.disabled
    var purifyMode = PurifyMode.disabled
    var origin = WindowOrigin.default
    var opacityEnabled = false
    var menuBarOpacity: Float = 1.0
    var activeOpacity: Float = 1.0
    var normalOpacity: Float = 1.0
    var opacityDuration: Float = 0.0
    var insertionFeedbackColor = RGBAColor(hex: 0xffd75f5f)
    var focusWrapping = FocusWrapping.on
}

struct MouseConfig
{
    var modifier = MouseModifierKey.fn
    var action1 = MouseAction.none
    var action2 = MouseAction.none
    var dropAction = MouseAction.none
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

struct BorderConfig
{
    var enabled = false
    var hideSingle = false
    var width: Float = 4.0
    var activeColor = RGBAColor(hex: 0xffe1e3e4)
    var normalColor = RGBAColor(hex: 0xff494d64)
}

struct TabBarConfig
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
