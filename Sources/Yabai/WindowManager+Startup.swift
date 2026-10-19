import ApplicationServices
import Foundation
import CPrivate
import YabaiCore

extension WindowManager
{
    func initialize()
    {
        let systemElement = AXUIElementCreateSystemWide()
        AXUIElementSetMessagingTimeout(systemElement, 1.0)
        self.systemElement = systemElement

        focusFollowsMouseMode = .disabled
        purifyMode = .disabled
        windowOriginMode = .default
        mouseFollowsFocusEnabled = false
        enable_window_opacity = false
        menubar_opacity = 1.0
        active_window_opacity = 1.0
        normal_window_opacity = 1.0
        window_opacity_duration = 0.0
        window_animation_duration = 0.0
        window_animation_easing = .easeOutCirc
        insert_feedback_color = rgba_color_from_hex(0xffd75f5f)
        enable_window_border = false
        window_border_hide_single = false
        window_border_width = 4.0
        active_window_border_color = rgba_color_from_hex(0xffe1e3e4)
        normal_window_border_color = rgba_color_from_hex(0xff494d64)
        focus_wrapping = .on
        enable_tab_bar = true
        tab_bar_height = 24
        tab_bar_offset = 0
        tab_bar_icons = true
        tab_bar_style = .glass
        tab_bar_appearance = .dark
        tab_bar_backdrop = .blur
        tab_bar_card_padding = 6
        tab_bar_window_radius = 16
        tab_bar_focused_color = rgba_color_from_hex(0xff285577)
        tab_bar_focused_text_color = rgba_color_from_hex(0xffffffff)
        tab_bar_inactive_color = rgba_color_from_hex(0xff5f676a)
        tab_bar_inactive_text_color = rgba_color_from_hex(0xffffffff)
        tab_bar_unfocused_color = rgba_color_from_hex(0xff222222)
        tab_bar_unfocused_text_color = rgba_color_from_hex(0xff888888)
        tab_bar_backdrop_color = rgba_color_from_hex(0xff48484a)
        _ = tab_bar_set_font(tabBarDefaultFont)
        scratchpad_exclusive = false
        scratchpad_raise = false
        scratchpad_below = false
        scratchpad_grid = Grid()

        application = [:]
        window = [:]
        managedWindows = [:]
        windowLostFocusedEvents = []
        applicationLostFrontSwitchedEvents = []
    }

    func begin()
    {
        autoreleasepool {
            // Applications in pid order, so their windows tile in the same order every start.
            for candidate in process_manager_global().process.values.sorted(by: { $0.pid < $1.pid }) {
                if workspace_application_is_observable(candidate) {
                    let created = Application(process: candidate)

                    if created.observe() {
                        addApplication(created)
                        _ = addExistingApplicationWindows(created, refreshIndex: nil)
                    } else {
                        created.unobserve()
                        created.destroy()
                    }
                } else {
                    debug("window_manager_begin: \(describe(candidate)) is not observable, subscribing to activationPolicy changes\n")
                    workspace_application_observe_activation_policy(candidate)
                }
            }
        }

        if let target = focusedWindow {
            lastWindowID = target.id
            focusedWindowID = target.id
            focusedWindowPSN = target.application.psn
            setWindowOpacity(target, to: active_window_opacity)
        }
    }
}
