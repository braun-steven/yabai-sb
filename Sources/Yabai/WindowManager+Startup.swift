import ApplicationServices
import Foundation
import CPrivate
import YabaiCore

extension WindowManager
{
    func initialize()
    {
        let systemElement = AXUIElement.systemWide()
        systemElement.setMessagingTimeout(1.0)
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
        insertionFeedbackColor = RGBAColor(hex: 0xffd75f5f)
        windowBorderEnabled = false
        windowBorderHideSingle = false
        windowBorderWidth = 4.0
        activeWindowBorderColor = RGBAColor(hex: 0xffe1e3e4)
        normalWindowBorderColor = RGBAColor(hex: 0xff494d64)
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
        tabBarFocusedColor = RGBAColor(hex: 0xff285577)
        tabBarFocusedTextColor = RGBAColor(hex: 0xffffffff)
        tabBarInactiveColor = RGBAColor(hex: 0xff5f676a)
        tabBarInactiveTextColor = RGBAColor(hex: 0xffffffff)
        tabBarUnfocusedColor = RGBAColor(hex: 0xff222222)
        tabBarUnfocusedTextColor = RGBAColor(hex: 0xff888888)
        tabBarBackdropColor = RGBAColor(hex: 0xff48484a)
        _ = TabBar.setFont(TabBar.defaultFont)
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
            for candidate in ProcessManager.shared.processes.values.sorted(by: { $0.pid < $1.pid }) {
                if candidate.isObservable() {
                    let created = Application(process: candidate)

                    if created.observe() {
                        addApplication(created)
                        _ = addExistingApplicationWindows(created, refreshIndex: nil)
                    } else {
                        created.unobserve()
                        created.destroy()
                    }
                } else {
                    debug("WindowManager.begin: \(candidate.nameAndPID) is not observable, subscribing to activationPolicy changes\n")
                    candidate.observeActivationPolicy()
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

    /// Requests the SkyLight notifications of all known windows. Daemon.run calls it before the event loop runs, so it is not @WM.
    func updateWindowNotifications()
    {
        // NOTE(asmvik): Subscribe to all windows because of the window destroyed (and ordered) notifications
        SLS.requestNotifications(SLS.connection, forWindows: window.values.map(\.id))
    }
}
