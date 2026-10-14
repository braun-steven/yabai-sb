import Testing
import YabaiC
import YabaiCore
@testable import Yabai

// NOTE: Ported from tests/src/message.c. The handler changes the C managers, so the tests run one at a time.

private func runConfig(_ message: String) -> String
{
    var response = Response()
    var source = Message(message)
    handleDomainConfig(&response, Token(Domain.config), &source)
    return response.text
}

@Suite(.serialized)
struct MessageConfigTests
{
    @Test("message_config_options")
    func messageConfigOptions()
    {
        let wm = window_manager_global()!
        let sm = space_manager_global()!
        let mouse = mouse_state_global()!

        let mff = wm.pointee.enable_mff
        let modifier = mouse.pointee.modifier
        let wrapping = wm.pointee.focus_wrapping
        let topPadding = sm.pointee.top_padding
        defer {
            wm.pointee.enable_mff = mff
            mouse.pointee.modifier = modifier
            wm.pointee.focus_wrapping = wrapping
            sm.pointee.top_padding = topPadding
        }

        _ = runConfig("mouse_follows_focus\0on\0mouse_modifier\0ctrl\0focus_wrapping\0force\0")
        #expect(wm.pointee.enable_mff)
        #expect(UInt32(mouse.pointee.modifier) == MOUSE_MOD_CTRL.rawValue)
        #expect(wm.pointee.focus_wrapping == FOCUS_WRAPPING_FORCE)

        #expect(runConfig("mouse_modifier\0") == "ctrl\n")
        #expect(runConfig("focus_wrapping\0") == "force\n")

        sm.pointee.top_padding = 7
        #expect(runConfig("top_padding\0") == "7\n")
        #expect(runConfig("top_padding\0-1\0").contains("unknown value '-1'"))
        #expect(sm.pointee.top_padding == 7)

        #expect(runConfig("not_an_option\0").contains("unknown command 'not_an_option'"))
    }

    @Test("message_config_values")
    func messageConfigValues()
    {
        let wm = window_manager_global()!
        let sm = space_manager_global()!

        let grid = wm.pointee.scratchpad_grid
        let duration = wm.pointee.window_animation_duration
        let opacityDuration = wm.pointee.window_opacity_duration
        let workspaceTabbed = sm.pointee.tree_workspace_tabbed
        defer {
            wm.pointee.scratchpad_grid = grid
            wm.pointee.window_animation_duration = duration
            wm.pointee.window_opacity_duration = opacityDuration
            sm.pointee.tree_workspace_tabbed = workspaceTabbed
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
