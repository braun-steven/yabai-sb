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
        @Test("tab_bar_appearance_config")
        func tabBarAppearanceConfig()
        {
            let wm = WindowManager.shared
            let appearance = wm.tabBarAppearance
            defer { wm.tabBarAppearance = appearance }
            wm.tabBarAppearance = .dark
            #expect(runConfig("tab_bar_appearance\0") == "dark\n")
            #expect(runConfig("tab_bar_appearance\0system\0").isEmpty)
            #expect(wm.tabBarAppearance == .system)
            #expect(runConfig("tab_bar_appearance\0") == "system\n")
            #expect(runConfig("tab_bar_appearance\0light\0").contains("unknown value 'light'"))
            #expect(wm.tabBarAppearance == .system)
            #expect(runConfig("tab_bar_appearance\0dark\0").isEmpty)
            #expect(wm.tabBarAppearance == .dark)
        }

        @Test("message_config_options")
        func messageConfigOptions()
        {
            let wm = WindowManager.shared
            let sm = SpaceManager.shared
            let mouse = MouseState.shared

            let mff = wm.mouseFollowsFocusEnabled
            let modifier = mouse.modifier
            let wrapping = wm.focusWrapping
            let topPadding = sm.topPadding
            defer {
                wm.mouseFollowsFocusEnabled = mff
                mouse.modifier = modifier
                wm.focusWrapping = wrapping
                sm.topPadding = topPadding
            }

            _ = runConfig("mouse_follows_focus\0on\0mouse_modifier\0ctrl\0focus_wrapping\0force\0")
            #expect(wm.mouseFollowsFocusEnabled)
            #expect(mouse.modifier == .ctrl)
            #expect(wm.focusWrapping == .force)

            #expect(runConfig("mouse_modifier\0") == "ctrl\n")
            #expect(runConfig("focus_wrapping\0") == "force\n")

            sm.topPadding = 7
            #expect(runConfig("top_padding\0") == "7\n")
            #expect(runConfig("top_padding\0-1\0").contains("unknown value '-1'"))
            #expect(sm.topPadding == 7)

            #expect(runConfig("not_an_option\0").contains("unknown command 'not_an_option'"))

            // NOTE: a failing option writes its failure and the next option still runs; an invalid space_layout stops
            // the message, since its layouts cannot be told apart from the next option
            #expect(runConfig("top_padding\0x\0top_padding\0") == "\u{07}unknown value 'x' given to command 'top_padding' for domain 'config'\n7\n")
            #expect(runConfig("space_layout\0x\0top_padding\0") == "\u{07}unknown value 'x' given to command 'space_layout' for domain 'config'\n")
        }

        @Test("message_config_values")
        func messageConfigValues()
        {
            let wm = WindowManager.shared
            let sm = SpaceManager.shared

            let grid = wm.scratchpadGrid
            let duration = wm.windowAnimationDuration
            let opacityDuration = wm.windowOpacityDuration
            let workspaceTabbed = sm.treeWorkspaceTabbed
            defer {
                wm.scratchpadGrid = grid
                wm.windowAnimationDuration = duration
                wm.windowOpacityDuration = opacityDuration
                sm.treeWorkspaceTabbed = workspaceTabbed
            }

            #expect(runConfig("scratchpad_grid\0off\0scratchpad_grid\0") == "off\n")
            #expect(runConfig("scratchpad_grid\04:4:1:1:2:2\0scratchpad_grid\0") == "4:4:1:1:2:2\n")
            #expect(runConfig("scratchpad_grid\00:4:1:1:2:2\0").contains("unknown value '0:4:1:1:2:2'"))

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
    }
}
