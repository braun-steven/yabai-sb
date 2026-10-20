import AppKit
import CPrivate
import YabaiCore

extension WindowManager
{
    func hasLostFrontSwitchedEvent(for pid: pid_t) -> Bool
    {
        applicationLostFrontSwitchedEvents.contains(pid)
    }

    func removeLostFrontSwitchedEvent(for pid: pid_t)
    {
        applicationLostFrontSwitchedEvents.remove(pid)
    }

    func addLostFrontSwitchedEvent(for pid: pid_t)
    {
        applicationLostFrontSwitchedEvents.insert(pid)
    }

    func hasLostFocusedEvent(for windowID: WindowID) -> Bool
    {
        windowLostFocusedEvents.contains(windowID)
    }

    func removeLostFocusedEvent(for windowID: WindowID)
    {
        windowLostFocusedEvents.remove(windowID)
    }

    func addLostFocusedEvent(for windowID: WindowID)
    {
        windowLostFocusedEvents.insert(windowID)
    }

    func window(for id: WindowID) -> Window?
    {
        window[id]
    }

    func removeWindow(_ id: WindowID)
    {
        Border.remove(id)
        window[id] = nil
    }

    func addWindow(_ target: Window)
    {
        if window[target.id] == nil { window[target.id] = target }
    }

    func application(for pid: pid_t) -> Application?
    {
        application[pid]
    }

    func removeApplication(pid: pid_t)
    {
        application.removeValue(forKey: pid)
    }

    func addApplication(_ owner: Application)
    {
        if application[owner.pid] == nil { application[owner.pid] = owner }
    }

    /// The windows owned by an application, in window id order.
    func windows(for owner: Application) -> [Window]
    {
        window.values.filter { $0.application == owner }
    }
}
