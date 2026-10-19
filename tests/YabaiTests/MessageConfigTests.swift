import Testing
import CPrivate
import YabaiCore
@testable import Yabai

// NOTE: The handler changes the global managers, so the tests are part of DaemonState.

@WM private func runConfig(_ message: String) -> String
{
    var response = Response()
    var source = Message(message)
    do {
        try handleDomainConfig(&response, Token(Domain.config), &source)
    } catch {
        response.fail(error)
    }
    return response.text
}

extension DaemonState
{
    @Suite
    @WM struct MessageConfigTests
    {
        @Test("config_option_table_is_complete")
        func optionTableCoversNames()
        {
            let expected: Set<String> = [
                "debug_output", "mouse_follows_focus", "focus_follows_mouse", "display_arrangement_order",
                "builtin_display_last", "window_origin_display", "window_opacity", "window_opacity_duration",
                "window_animation_duration", "window_animation_easing", "window_shadow", "menubar_opacity",
                "active_window_opacity", "normal_window_opacity", "insert_feedback_color", "window_border",
                "window_border_width", "window_border_hide_single", "active_window_border_color",
                "normal_window_border_color", "tab_bar", "tab_bar_height", "tab_bar_offset", "tab_bar_font",
                "tab_bar_icons", "tab_bar_style", "tab_bar_appearance", "tab_bar_backdrop", "tab_bar_card_padding",
                "tab_bar_window_radius", "tab_bar_focused_color", "tab_bar_focused_text_color",
                "tab_bar_inactive_color", "tab_bar_inactive_text_color", "tab_bar_unfocused_color",
                "tab_bar_unfocused_text_color", "tab_bar_backdrop_color", "top_padding", "bottom_padding",
                "left_padding", "right_padding", "window_gap", "layout", "auto_padding", "tree_default_orientation",
                "tree_workspace_layout", "tree_autotiling", "focus_wrapping", "mouse_modifier", "mouse_action1",
                "mouse_action2", "mouse_drop_action", "external_bar", "skip_window_focus_animation", "space_layout",
                "scratchpad_exclusive", "scratchpad_raise", "scratchpad_below", "scratchpad_grid",
            ]
            let actual = configOptionNames.map(\.rawValue)

            #expect(configOptionTableIsComplete)
            #expect(ConfigName.allCases.count == 59)
            #expect(actual.count == 59)
            #expect(Set(actual).count == actual.count)
            #expect(Set(actual) == expected)
        }

        @Test("tab_bar_appearance_config")
        func tabBarAppearanceConfig()
        {
            let appearance = Config.current.tabBar.appearance
            defer { Config.current.tabBar.appearance = appearance }
            Config.current.tabBar.appearance = .dark
            #expect(runConfig("tab_bar_appearance\0") == "dark\n")
            #expect(runConfig("tab_bar_appearance\0system\0").isEmpty)
            #expect(Config.current.tabBar.appearance == .system)
            #expect(runConfig("tab_bar_appearance\0") == "system\n")
            #expect(runConfig("tab_bar_appearance\0light\0").contains("unknown value 'light'"))
            #expect(Config.current.tabBar.appearance == .system)
            #expect(runConfig("tab_bar_appearance\0dark\0").isEmpty)
            #expect(Config.current.tabBar.appearance == .dark)
        }

        @Test("message_config_options")
        func messageConfigOptions()
        {
            let mouse = Config.current.mouse
            let tap = MouseState.shared.tap

            let mff = Config.current.window.mouseFollowsFocusEnabled
            let modifier = mouse.modifier
            let wrapping = Config.current.window.focusWrapping
            let topPadding = Config.current.space.topPadding
            defer {
                Config.current.window.mouseFollowsFocusEnabled = mff
                Config.current.mouse.modifier = modifier
                tap.modifier = modifier
                Config.current.window.focusWrapping = wrapping
                Config.current.space.topPadding = topPadding
            }

            _ = runConfig("mouse_follows_focus\0on\0mouse_modifier\0ctrl\0focus_wrapping\0force\0")
            #expect(Config.current.window.mouseFollowsFocusEnabled)
            #expect(Config.current.mouse.modifier == .ctrl)
            #expect(tap.modifier == .ctrl)
            #expect(Config.current.window.focusWrapping == .force)

            #expect(runConfig("mouse_modifier\0") == "ctrl\n")
            #expect(runConfig("focus_wrapping\0") == "force\n")

            Config.current.space.topPadding = 7
            #expect(runConfig("top_padding\0") == "7\n")
            #expect(runConfig("top_padding\0-1\0").contains("unknown value '-1'"))
            #expect(Config.current.space.topPadding == 7)

            #expect(runConfig("not_an_option\0").contains("unknown command 'not_an_option'"))

            // NOTE: a failing option writes its failure and the next option still runs; an invalid space_layout stops
            // the message, since its layouts cannot be told apart from the next option
            #expect(runConfig("top_padding\0x\0top_padding\0") == "\u{07}unknown value 'x' given to command 'top_padding' for domain 'config'\n7\n")
            #expect(runConfig("space_layout\0x\0top_padding\0") == "\u{07}unknown value 'x' given to command 'space_layout' for domain 'config'\n")
        }

        @Test("message_config_values")
        func messageConfigValues()
        {
            let grid = Config.current.scratchpad.scratchpadGrid
            let duration = Config.current.animation.windowAnimationDuration
            let opacityDuration = Config.current.window.windowOpacityDuration
            let workspaceTabbed = Config.current.space.treeWorkspaceTabbed
            defer {
                Config.current.scratchpad.scratchpadGrid = grid
                Config.current.animation.windowAnimationDuration = duration
                Config.current.window.windowOpacityDuration = opacityDuration
                Config.current.space.treeWorkspaceTabbed = workspaceTabbed
            }

            #expect(runConfig("scratchpad_grid\0off\0scratchpad_grid\0") == "off\n")
            #expect(runConfig("scratchpad_grid\04:4:1:1:2:2\0scratchpad_grid\0") == "4:4:1:1:2:2\n")
            #expect(runConfig("scratchpad_grid\00:4:1:1:2:2\0").contains("unknown value '0:4:1:1:2:2'"))
            #expect(runConfig("scratchpad_grid\0-1:4:1:1:2:2\0scratchpad_grid\0") == "4294967295:4:1:1:2:2\n")

            #expect(runConfig("window_animation_duration\00\0window_animation_duration\0") == "0.000000\n")
            #expect(runConfig("window_animation_duration\0fast\0").contains("unknown value 'fast'"))

            #expect(runConfig("layout\0bsp\0").contains("unknown value 'bsp'"))
            #expect(runConfig("external_bar\0some:1:2\0").contains("unknown mode 'some'"))

            // NOTE: float options also take integers
            #expect(runConfig("window_opacity_duration\01\0window_opacity_duration\0") == "1.000000\n")

            // NOTE: only the menubar accepts an opacity of 0
            #expect(runConfig("active_window_opacity\00\0").contains("unknown value '0'"))
            #expect(runConfig("menubar_opacity\01.5\0").contains("unknown value '1.5'"))
            #expect(runConfig("normal_window_opacity\0half\0").contains("unknown value 'half'"))

            #expect(runConfig("tree_workspace_layout\0tabbed\0tree_workspace_layout\0") == "tabbed\n")
            #expect(runConfig("tree_workspace_layout\0default\0tree_workspace_layout\0") == "default\n")
            #expect(runConfig("tree_workspace_layout\0stacked\0").contains("unknown value 'stacked'"))
        }

        @Test("numeric_and_color_config_values_validate_before_applying")
        func numericAndColorConfigValuesValidateBeforeApplying()
        {
            let duration = Config.current.window.windowOpacityDuration
            let insertionColor = Config.current.window.insertionFeedbackColor
            let focusedColor = Config.current.tabBar.focusedColor
            let focusedColorIsCustom = Config.current.tabBar.focusedColorIsCustom
            defer {
                Config.current.window.windowOpacityDuration = duration
                Config.current.window.insertionFeedbackColor = insertionColor
                Config.current.tabBar.focusedColor = focusedColor
                Config.current.tabBar.focusedColorIsCustom = focusedColorIsCustom
            }

            #expect(runConfig("window_opacity_duration\00.25\0window_opacity_duration\0") == "0.250000\n")
            #expect(Config.current.window.windowOpacityDuration == 0.25)
            #expect(runConfig("window_opacity_duration\0fast\0").contains("unknown value 'fast'"))
            #expect(Config.current.window.windowOpacityDuration == 0.25)

            #expect(runConfig("insert_feedback_color\00xff123456\0insert_feedback_color\0") == "0xff123456\n")
            #expect(Config.current.window.insertionFeedbackColor.argb == 0xff123456)
            #expect(runConfig("insert_feedback_color\00\0").contains("unknown value '0'"))
            #expect(Config.current.window.insertionFeedbackColor.argb == 0xff123456)

            Config.current.tabBar.focusedColorIsCustom = false
            #expect(runConfig("tab_bar_focused_color\00xffabcdef\0tab_bar_focused_color\0") == "0xffabcdef\n")
            #expect(Config.current.tabBar.focusedColor.argb == 0xffabcdef)
            #expect(Config.current.tabBar.focusedColorIsCustom)
        }
    }
}
