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
        windowOpacityEnabled = false
        menuBarOpacity = 1.0
        activeWindowOpacity = 1.0
        normalWindowOpacity = 1.0
        windowOpacityDuration = 0.0
        windowAnimationDuration = 0.0
        windowAnimationEasing = .easeOutCirc
        insertionFeedbackColor = rgba_color_from_hex(0xffd75f5f)
        windowBorderEnabled = false
        windowBorderHideSingle = false
        windowBorderWidth = 4.0
        activeWindowBorderColor = rgba_color_from_hex(0xffe1e3e4)
        normalWindowBorderColor = rgba_color_from_hex(0xff494d64)
        focusWrapping = .on
        tabBarEnabled = true
        tabBarHeight = 24
        tabBarOffset = 0
        tabBarIcons = true
        tabBarStyle = .glass
        tabBarAppearance = .dark
        tabBarBackdrop = .blur
        tabBarCardPadding = 6
        tabBarWindowRadius = 16
        tabBarFocusedColor = rgba_color_from_hex(0xff285577)
        tabBarFocusedTextColor = rgba_color_from_hex(0xffffffff)
        tabBarInactiveColor = rgba_color_from_hex(0xff5f676a)
        tabBarInactiveTextColor = rgba_color_from_hex(0xffffffff)
        tabBarUnfocusedColor = rgba_color_from_hex(0xff222222)
        tabBarUnfocusedTextColor = rgba_color_from_hex(0xff888888)
        tabBarBackdropColor = rgba_color_from_hex(0xff48484a)
        _ = tab_bar_set_font(tabBarDefaultFont)
        scratchpadExclusive = false
        scratchpadRaise = false
        scratchpadBelow = false
        scratchpadGrid = Grid()

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
            setWindowOpacity(target, to: activeWindowOpacity)
        }
    }
}
