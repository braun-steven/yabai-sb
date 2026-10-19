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
        focusWrapping = .on
        Config.current = Config()
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
