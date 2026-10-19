import AppKit
import CPrivate
import YabaiCore

extension WindowManager
{
    func hasLostFrontSwitchedEvent(for pid: pid_t) -> Bool
    {
        application_lost_front_switched_event.contains(pid)
    }

    func removeLostFrontSwitchedEvent(for pid: pid_t)
    {
        application_lost_front_switched_event.remove(pid)
    }

    func addLostFrontSwitchedEvent(for pid: pid_t)
    {
        application_lost_front_switched_event.insert(pid)
    }

    func hasLostFocusedEvent(for windowID: WindowID) -> Bool
    {
        window_lost_focused_event.contains(windowID)
    }

    func removeLostFocusedEvent(for windowID: WindowID)
    {
        window_lost_focused_event.remove(windowID)
    }

    func addLostFocusedEvent(for windowID: WindowID)
    {
        window_lost_focused_event.insert(windowID)
    }

    func window(for id: WindowID) -> Window?
    {
        window[id]
    }

    func removeWindow(_ id: WindowID)
    {
        border_remove(id)
        window.removeValue(forKey: id)
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
        window.values.filter { $0.application == owner }.sorted { $0.id < $1.id }
    }
}
