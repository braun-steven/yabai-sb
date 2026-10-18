import Testing
import CPrivate
import YabaiCore
@testable import Yabai

// NOTE: The handler changes the global managers, so the tests are part of DaemonState.

private func runConfig(_ message: String) -> String
{
    var response = Response()
    var source = Message(message)
    handleDomainConfig(&response, Token(Domain.config), &source)
    return response.text
}

extension DaemonState
{
    @Suite
    struct MessageConfigTests
    {
        @Test("tab_bar_appearance_config")
        func tabBarAppearanceConfig()
        {
            let wm = window_manager_global()
            let appearance = wm.tab_bar_appearance
            defer { wm.tab_bar_appearance = appearance }
            wm.tab_bar_appearance = .dark
            #expect(runConfig("tab_bar_appearance\0") == "dark\n")
            #expect(runConfig("tab_bar_appearance\0system\0").isEmpty)
            #expect(wm.tab_bar_appearance == .system)
            #expect(runConfig("tab_bar_appearance\0") == "system\n")
            #expect(runConfig("tab_bar_appearance\0light\0").contains("unknown value 'light'"))
            #expect(wm.tab_bar_appearance == .system)
            #expect(runConfig("tab_bar_appearance\0dark\0").isEmpty)
            #expect(wm.tab_bar_appearance == .dark)
        }

        @Test("message_config_options")
        func messageConfigOptions()
        {
            let wm = window_manager_global()
            let sm = space_manager_global()
            let mouse = mouse_state_global()

            let mff = wm.enable_mff
            let modifier = mouse.modifier
            let wrapping = wm.focus_wrapping
            let topPadding = sm.top_padding
            defer {
                wm.enable_mff = mff
                mouse.modifier = modifier
                wm.focus_wrapping = wrapping
                sm.top_padding = topPadding
            }

            _ = runConfig("mouse_follows_focus\0on\0mouse_modifier\0ctrl\0focus_wrapping\0force\0")
            #expect(wm.enable_mff)
            #expect(UInt32(mouse.modifier) == MOUSE_MOD_CTRL.rawValue)
            #expect(wm.focus_wrapping == .force)

            #expect(runConfig("mouse_modifier\0") == "ctrl\n")
            #expect(runConfig("focus_wrapping\0") == "force\n")

            sm.top_padding = 7
            #expect(runConfig("top_padding\0") == "7\n")
            #expect(runConfig("top_padding\0-1\0").contains("unknown value '-1'"))
            #expect(sm.top_padding == 7)

            #expect(runConfig("not_an_option\0").contains("unknown command 'not_an_option'"))
        }

        @Test("message_config_values")
        func messageConfigValues()
        {
            let wm = window_manager_global()
            let sm = space_manager_global()

            let grid = wm.scratchpad_grid
            let duration = wm.window_animation_duration
            let opacityDuration = wm.window_opacity_duration
            let workspaceTabbed = sm.tree_workspace_tabbed
            defer {
                wm.scratchpad_grid = grid
                wm.window_animation_duration = duration
                wm.window_opacity_duration = opacityDuration
                sm.tree_workspace_tabbed = workspaceTabbed
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
