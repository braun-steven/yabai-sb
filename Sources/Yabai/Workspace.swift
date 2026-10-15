import AppKit
import CPrivate
import YabaiC

//
// NOTE: The NSWorkspace, distributed and local notifications that yabai follows, and the key-value observations of the
// NSRunningApplication of a process (finishedLaunching, activationPolicy). The notifications arrive on the main thread,
// the key-value changes on the thread that changes the property (or inside addObserver, for the initial value); both only
// post events. Ported from src/workspace.m; the context object is a Swift global instead of g_workspace_context.
//

private enum KeyPath
{
    static let activationPolicy  = "activationPolicy"
    static let finishedLaunching = "finishedLaunching"
}

//
// NOTE: Sendable: the context has no stored state; it only receives notifications and key-value changes on any thread.
//

final class WorkspaceContext: NSObject, Sendable
{
    override init()
    {
        super.init()

        NSWorkspace.shared.notificationCenter.addObserver(self,
                selector: #selector(activeDisplayDidChange(_:)),
                name: NSNotification.Name("NSWorkspaceActiveDisplayDidChangeNotification"),
                object: nil)

        NSWorkspace.shared.notificationCenter.addObserver(self,
                selector: #selector(activeSpaceDidChange(_:)),
                name: NSWorkspace.activeSpaceDidChangeNotification,
                object: nil)

        NSWorkspace.shared.notificationCenter.addObserver(self,
                selector: #selector(didHideApplication(_:)),
                name: NSWorkspace.didHideApplicationNotification,
                object: nil)

        NSWorkspace.shared.notificationCenter.addObserver(self,
                selector: #selector(didUnhideApplication(_:)),
                name: NSWorkspace.didUnhideApplicationNotification,
                object: nil)

        NSWorkspace.shared.notificationCenter.addObserver(self,
                selector: #selector(didWake(_:)),
                name: NSWorkspace.didWakeNotification,
                object: nil)

        DistributedNotificationCenter.default().addObserver(self,
                selector: #selector(didChangeMenuBarHiding(_:)),
                name: NSNotification.Name("AppleInterfaceMenuBarHidingChangedNotification"),
                object: nil)

        NotificationCenter.default.addObserver(self,
                selector: #selector(didRestartDock(_:)),
                name: NSNotification.Name("NSApplicationDockDidRestartNotification"),
                object: nil)

        DistributedNotificationCenter.default().addObserver(self,
                selector: #selector(didChangeDockPref(_:)),
                name: NSNotification.Name("com.apple.dock.prefchanged"),
                object: nil)
    }

    deinit
    {
        NSWorkspace.shared.notificationCenter.removeObserver(self)
        NotificationCenter.default.removeObserver(self)
        DistributedNotificationCenter.default().removeObserver(self)
    }

    override func observeValue(forKeyPath keyPath: String?, of object: Any?, change: [NSKeyValueChangeKey: Any]?, context: UnsafeMutableRawPointer?)
    {
        if keyPath == KeyPath.activationPolicy {
            let process = context!.assumingMemoryBound(to: YabaiC.process.self)
            if process_is_terminated_acquire(process) { return }

            let result = (change?[.newKey] as? NSNumber)?.int32Value ?? 0
            if result != process.pointee.policy {
                //
                // :WorstApiEverMade
                //
                // NOTE(asmvik): For some stupid reason it is possible to get notified by the system
                // about a change, and NOT being able to remove ourselves from observation because
                // it claims that we are not observing the key-path, but we clearly are, as we would
                // otherwise not be here in the first place..
                //

                NSObjectRemoveObserverC(object as! NSObject, self, KeyPath.activationPolicy, context)

                process.pointee.policy = result
                debug("-[workspace_context observeValueForKeyPath:ofObject:change:context:]: activation policy changed for \(describe(process))\n")
                EventLoop.post(.applicationLaunched(Handoff(value: process)))
            }
        }

        if keyPath == KeyPath.finishedLaunching {
            let process = context!.assumingMemoryBound(to: YabaiC.process.self)
            if process_is_terminated_acquire(process) { return }

            let result = (change?[.newKey] as? NSNumber)?.int32Value ?? 0
            if result == 1 {
                //
                // :WorstApiEverMade
                //
                // NOTE(asmvik): For some stupid reason it is possible to get notified by the system
                // about a change, and NOT being able to remove ourselves from observation because
                // it claims that we are not observing the key-path, but we clearly are, as we would
                // otherwise not be here in the first place..
                //

                NSObjectRemoveObserverC(object as! NSObject, self, KeyPath.finishedLaunching, context)

                debug("-[workspace_context observeValueForKeyPath:ofObject:change:context:]: \(describe(process)) finished launching\n")
                EventLoop.post(.applicationLaunched(Handoff(value: process)))
            }
        }
    }

    @objc func didWake(_ notification: Notification)
    {
        EventLoop.post(.systemWoke)
    }

    @objc func didChangeMenuBarHiding(_ notification: Notification)
    {
        EventLoop.post(.menuBarHiddenChanged)
    }

    @objc func didRestartDock(_ notification: Notification)
    {
        EventLoop.post(.dockDidRestart)
    }

    @objc func didChangeDockPref(_ notification: Notification)
    {
        EventLoop.post(.dockDidChangePref)
    }

    @objc func activeDisplayDidChange(_ notification: Notification)
    {
        EventLoop.post(.displayChanged)
    }

    @objc func activeSpaceDidChange(_ notification: Notification)
    {
        EventLoop.post(.spaceChanged)
    }

    @objc func didHideApplication(_ notification: Notification)
    {
        let pid = (notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication)?.processIdentifier ?? 0
        EventLoop.post(.applicationHidden(pid: pid))
    }

    @objc func didUnhideApplication(_ notification: Notification)
    {
        let pid = (notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication)?.processIdentifier ?? 0
        EventLoop.post(.applicationVisible(pid: pid))
    }
}

// created by workspace_event_handler_begin, and alive as long as the daemon
private let workspaceContext = WorkspaceContext()

/// `workspace_event_handler_begin`: called by yabai_main on the main thread, before the event loop starts.
@_cdecl("workspace_event_handler_begin")
func workspace_event_handler_begin() -> Bool
{
    _ = workspaceContext
    return true
}

//
// NOTE: process->ns_application holds the NSRunningApplication at +1 (passRetained), from
// workspace_application_create_running_ns_application until workspace_application_destroy_running_ns_application.
//

/// `workspace_application_create_running_ns_application`: the retained NSRunningApplication of the process, or nil.
func workspace_application_create_running_ns_application(_ process: UnsafeMutablePointer<process>) -> UnsafeMutableRawPointer?
{
    return NSRunningApplication(processIdentifier: process.pointee.pid).map { Unmanaged.passRetained($0).toOpaque() }
}

private func runningApplication(_ process: UnsafeMutablePointer<process>) -> NSRunningApplication?
{
    return process_ns_application(process).map { Unmanaged<NSRunningApplication>.fromOpaque($0).takeUnretainedValue() }
}

//
// NOTE: Removing an observation that is not registered throws, and there is no way to list the
// registered observations, so failures are ignored.
//

private func workspaceApplicationRemoveObserver(_ application: NSRunningApplication, _ process: UnsafeMutablePointer<process>, _ keyPath: String)
{
    NSObjectRemoveObserverC(application, workspaceContext, keyPath, UnsafeMutableRawPointer(process))
}

/// `workspace_application_destroy_running_ns_application`
func workspace_application_destroy_running_ns_application(_ process: UnsafeMutablePointer<process>)
{
    guard let pointer = process_ns_application(process) else { return }
    let application = Unmanaged<NSRunningApplication>.fromOpaque(pointer)

    if application.takeUnretainedValue().observationInfo != nil {

        //
        // :WorstApiEverMade
        //
        // NOTE(asmvik): Because the developers of this API did such an amazing job
        // there is no way for us to actually just friggin loop through the currently
        // registered observations and then call removeObservation on them..
        //
        // Instead we just try to force remove the observations that **could** be present
        // at this point in time, because it will complain if we try to actually release
        // the object when it has observers present.
        //
        // We can't actually correctly track whether it did actually get unobserved previously,
        // because even when our notification callback is triggered it will claim that we try
        // to remove a non-existing observation when it just called us back.
        //

        workspaceApplicationRemoveObserver(application.takeUnretainedValue(), process, KeyPath.activationPolicy)
        workspaceApplicationRemoveObserver(application.takeUnretainedValue(), process, KeyPath.finishedLaunching)
    }

    application.release()
}

private func workspaceApplicationAddObserver(_ process: UnsafeMutablePointer<process>, _ keyPath: String)
{
    if let application = runningApplication(process) {
        application.addObserver(workspaceContext, forKeyPath: keyPath, options: [.initial, .new], context: UnsafeMutableRawPointer(process))
    } else {
        debug("workspace_application_add_observer: could not subscribe to \(keyPath) changes for \(describe(process))\n")
    }
}

/// `workspace_application_observe_finished_launching`
func workspace_application_observe_finished_launching(_ process: UnsafeMutablePointer<process>)
{
    workspaceApplicationAddObserver(process, KeyPath.finishedLaunching)
}

/// `workspace_application_observe_activation_policy`: window_manager_begin calls it for a process that is not observable.
func workspace_application_observe_activation_policy(_ process: UnsafeMutablePointer<process>)
{
    workspaceApplicationAddObserver(process, KeyPath.activationPolicy)
}

private func workspaceApplicationRemoveObserverIfObserved(_ process: UnsafeMutablePointer<process>, _ keyPath: String)
{
    if let application = runningApplication(process), application.observationInfo != nil {
        workspaceApplicationRemoveObserver(application, process, keyPath)
    }
}

/// `workspace_application_unobserve_finished_launching`
func workspace_application_unobserve_finished_launching(_ process: UnsafeMutablePointer<process>)
{
    workspaceApplicationRemoveObserverIfObserved(process, KeyPath.finishedLaunching)
}

/// `workspace_application_unobserve_activation_policy`
func workspace_application_unobserve_activation_policy(_ process: UnsafeMutablePointer<process>)
{
    workspaceApplicationRemoveObserverIfObserved(process, KeyPath.activationPolicy)
}

/// `workspace_application_unobserve`: called by the process handler when the process terminates.
func workspace_application_unobserve(_ process: UnsafeMutablePointer<process>)
{
    if let application = runningApplication(process) {
        workspaceApplicationRemoveObserver(application, process, KeyPath.activationPolicy)
        workspaceApplicationRemoveObserver(application, process, KeyPath.finishedLaunching)
    }
}

/// `workspace_application_is_observable`: whether the process is a regular application; stores its policy.
func workspace_application_is_observable(_ process: UnsafeMutablePointer<process>) -> Bool
{
    if let application = runningApplication(process) {
        process.pointee.policy = Int32(application.activationPolicy.rawValue)
        return process.pointee.policy == Int32(NSApplication.ActivationPolicy.regular.rawValue)
    } else {
        process.pointee.policy = Int32(NSApplication.ActivationPolicy.prohibited.rawValue)
        return false
    }
}

/// `workspace_application_is_finished_launching`
func workspace_application_is_finished_launching(_ process: UnsafeMutablePointer<process>) -> Bool
{
    return runningApplication(process)?.isFinishedLaunching ?? false
}

/// `workspace_display_notch_height`: the top safe area inset of a builtin display, else 0.
func workspace_display_notch_height(_ did: UInt32) -> Int32
{
    if CGDisplayIsBuiltin(did) == 0 { return 0 }

    for screen in NSScreen.screens {
        if (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value == did {
            return Int32(screen.safeAreaInsets.top)
        }
    }

    return 0
}

/// `workspace_get_dock_pid`: the pid of the Dock, or 0.
func workspace_get_dock_pid() -> pid_t
{
    let list = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.dock")

    if list.count == 1 {
        return list[0].processIdentifier
    }

    return 0
}
