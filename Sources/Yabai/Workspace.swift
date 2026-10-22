import AppKit
import CPrivate
import YabaiCore
import Logging
import Synchronization

//
// NOTE: The NSWorkspace, distributed and local notifications that yabai follows, and the key-value observations of the
// NSRunningApplication of a process (finishedLaunching, activationPolicy). The notifications arrive on the main thread,
// the key-value changes on the thread that changes the property (or inside addObserver, for the initial value); both only
// post events.
//

private enum KeyPath
{
    static let activationPolicy  = "activationPolicy"
    static let finishedLaunching = "finishedLaunching"
}

//
// NOTE: Sendable: the context has no stored state; it only receives notifications and key-value changes on any thread.
//

final class Workspace: NSObject, Sendable
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
            let process = Unmanaged<Process>.fromOpaque(context!).takeUnretainedValue()
            if process.terminated.load(ordering: .acquiring) { return }

            let result = (change?[.newKey] as? NSNumber)?.intValue ?? 0
            if result != process.policy.load(ordering: .relaxed) {
                //
                // :WorstApiEverMade
                //
                // NOTE(asmvik): For some stupid reason it is possible to get notified by the system
                // about a change, and NOT being able to remove ourselves from observation because
                // it claims that we are not observing the key-path, but we clearly are, as we would
                // otherwise not be here in the first place..
                //

                NSObjectRemoveObserverC(object as! NSObject, self, KeyPath.activationPolicy, context)

                process.policy.store(result, ordering: .relaxed)
                Logger.processes.debug("activation policy changed for \(process.nameAndPID)")
                EventLoop.post(.applicationLaunched(process))
            }
        }

        if keyPath == KeyPath.finishedLaunching {
            let process = Unmanaged<Process>.fromOpaque(context!).takeUnretainedValue()
            if process.terminated.load(ordering: .acquiring) { return }

            let result = (change?[.newKey] as? NSNumber)?.intValue ?? 0
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

                Logger.processes.debug("\(process.nameAndPID) finished launching")
                EventLoop.post(.applicationLaunched(process))
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

    //
    // NOTE: A notification without an application has no pid to act on, so nothing is posted (the handlers ignore an
    // unknown pid anyway).
    //

    @objc func didHideApplication(_ notification: Notification)
    {
        guard let pid = (notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication)?.processIdentifier else { return }
        EventLoop.post(.applicationHidden(pid: pid))
    }

    @objc func didUnhideApplication(_ notification: Notification)
    {
        guard let pid = (notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication)?.processIdentifier else { return }
        EventLoop.post(.applicationVisible(pid: pid))
    }

    /// Created by `begin()`, and alive as long as the daemon.
    static let shared = Workspace()

    /// Called by Daemon.run on the main thread, before the event loop starts.
    static func begin() -> Bool
    {
        _ = shared
        return true
    }

    /// The pid of the Dock, or nil.
    static var dockPID: pid_t?
    {
        let list = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.dock")

        if list.count == 1 {
            return list[0].processIdentifier
        }

        return nil
    }
}

//
// NOTE: runningApplicationBox holds the NSRunningApplication from attachRunningApplication() until
// releaseRunningApplication(), which drops it. The context of the key-value observations is the process, unretained: its
// observations are removed when the process terminates (unobserve()), before the handler of APPLICATION_TERMINATED
// releases it.
//

extension Process
{
    private var observationContext: UnsafeMutableRawPointer
    {
        return Unmanaged.passUnretained(self).toOpaque()
    }

    /// Stores the NSRunningApplication of the process, or nil when AppKit does not know the pid.
    func attachRunningApplication()
    {
        let box = NSRunningApplication(processIdentifier: pid).map(RunningApplicationBox.init)
        runningApplicationBox.withLock { $0 = box }
    }

    var runningApplication: NSRunningApplication?
    {
        return runningApplicationBox.withLock { $0 }?.application
    }

    //
    // NOTE: Removing an observation that is not registered throws, and there is no way to list the
    // registered observations, so failures are ignored.
    //

    private func removeObserver(from application: NSRunningApplication, _ keyPath: String)
    {
        NSObjectRemoveObserverC(application, Workspace.shared, keyPath, observationContext)
    }

    func releaseRunningApplication()
    {
        guard let application = runningApplication else { return }

        if application.observationInfo != nil {

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

            removeObserver(from: application, KeyPath.activationPolicy)
            removeObserver(from: application, KeyPath.finishedLaunching)
        }

        runningApplicationBox.withLock { $0 = nil }
    }

    private func addObserver(_ keyPath: String)
    {
        if let application = runningApplication {
            application.addObserver(Workspace.shared, forKeyPath: keyPath, options: [.initial, .new], context: observationContext)
        } else {
            Logger.processes.debug("could not subscribe to \(keyPath) changes for \(self.nameAndPID)")
        }
    }

    func observeFinishedLaunching()
    {
        addObserver(KeyPath.finishedLaunching)
    }

    /// Called by WindowManager.begin for a process that is not observable.
    func observeActivationPolicy()
    {
        addObserver(KeyPath.activationPolicy)
    }

    private func removeObserverIfObserved(_ keyPath: String)
    {
        if let application = runningApplication, application.observationInfo != nil {
            removeObserver(from: application, keyPath)
        }
    }

    func unobserveFinishedLaunching()
    {
        removeObserverIfObserved(KeyPath.finishedLaunching)
    }

    func unobserveActivationPolicy()
    {
        removeObserverIfObserved(KeyPath.activationPolicy)
    }

    /// Called by the process handler when the process terminates.
    func unobserve()
    {
        if let application = runningApplication {
            removeObserver(from: application, KeyPath.activationPolicy)
            removeObserver(from: application, KeyPath.finishedLaunching)
        }
    }

    /// Whether the process is a regular application; stores its activation policy in `policy`.
    func isObservable() -> Bool
    {
        if let application = runningApplication {
            let value = application.activationPolicy.rawValue
            policy.store(value, ordering: .relaxed)
            return value == NSApplication.ActivationPolicy.regular.rawValue
        } else {
            policy.store(NSApplication.ActivationPolicy.prohibited.rawValue, ordering: .relaxed)
            return false
        }
    }

    var isFinishedLaunching: Bool
    {
        return runningApplication?.isFinishedLaunching ?? false
    }
}

extension DisplayID
{
    /// The top safe area inset of a builtin display, else 0.
    var notchHeight: Int
    {
        if CGDisplayIsBuiltin(rawValue) == 0 { return 0 }

        for screen in NSScreen.screens {
            if (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value == rawValue {
                return Int(screen.safeAreaInsets.top)
            }
        }

        return 0
    }
}
