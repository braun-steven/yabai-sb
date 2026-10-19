import YabaiCore

@WM struct Config
{
    static var current = Config()

    var border = BorderConfig()
    var tabBar = TabBarConfig()
    var window = WindowConfig()
    var animation = AnimationConfig()
    var scratchpad = ScratchpadConfig()
}

struct WindowConfig
{
    var mouseFollowsFocusEnabled = false
    var focusFollowsMouseMode = FocusFollowsMouse.disabled
    var purifyMode = PurifyMode.disabled
    var windowOriginMode = WindowOrigin.default
    var windowOpacityEnabled = false
    var menuBarOpacity: Float = 1.0
    var activeWindowOpacity: Float = 1.0
    var normalWindowOpacity: Float = 1.0
    var windowOpacityDuration: Float = 0.0
    var insertionFeedbackColor = RGBAColor(hex: 0xffd75f5f)
    var focusWrapping = FocusWrapping.on
}

struct AnimationConfig
{
    var windowAnimationDuration: Float = 0.0
    var windowAnimationEasing = AnimationEasing.easeOutCirc
}

struct ScratchpadConfig
{
    var scratchpadExclusive = false
    var scratchpadRaise = false
    var scratchpadBelow = false
    var scratchpadGrid = Grid()
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
