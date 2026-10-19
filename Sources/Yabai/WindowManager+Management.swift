import AppKit
import CoreGraphics
import CPrivate
import YabaiCore

extension WindowManager
{
    // NOTE: Refresh, rule and scratchpad lists remove an item by moving the last element into its slot.

    func applicationRefreshIndex(of application: Application) -> Int?
    {
        applicationsToRefresh.firstIndex(of: application)
    }

    func removeApplicationRefresh(at index: Int)
    {
        applicationsToRefresh.swapAt(index, applicationsToRefresh.count - 1)
        applicationsToRefresh.removeLast()
    }

    var applicationRefreshCount: Int { applicationsToRefresh.count }

    func applicationRefresh(at index: Int) -> Application
    {
        applicationsToRefresh[index]
    }

    func addApplicationToRefresh(_ application: Application)
    {
        applicationsToRefresh.append(application)
    }

    var scratchpadCount: Int { scratchpads.count }

    func addScratchpad(label: String, window: Window)
    {
        scratchpads.append(Scratchpad(label: label, window: window))
    }

    func removeScratchpad(at index: Int)
    {
        scratchpads.swapAt(index, scratchpads.count - 1)
        scratchpads.removeLast()
    }

    func setFocusFollowsMouse(_ mode: FocusFollowsMouse)
    {
        MouseState.shared.endEventTap()

        if mode == .disabled {
            MouseState.shared.beginEventTap(mask: mouseEventMask)
        } else {
            MouseState.shared.beginEventTap(mask: mouseEventMaskFFM)
        }

        Config.current.window.focusFollowsMouse = mode
    }

    func setWindowOpacityEnabled(_ enabled: Bool)
    {
        Config.current.window.opacityEnabled = enabled
        for target in window.values where target.isEligibleForManagement {
            setOpacity(for: target, to: enabled ? target.opacity : 1.0)
        }
    }

    func centerMouse(on target: Window)
    {
        if !(target.mouseFollowsFocusByRule ?? Config.current.window.mouseFollowsFocus) { return }

        let cursor = SLS.cursorLocation(SLS.connection)
        if target.frame.contains(cursor) { return }

        guard let did = target.id.displayID else { return }

        let center = CGPoint(x: target.frame.origin.x + target.frame.size.width / 2,
                             y: target.frame.origin.y + target.frame.size.height / 2)

        let bounds = CGDisplayBounds(did.rawValue)
        if !bounds.contains(center) { return }

        CGWarpMouseCursorPosition(center)
    }

    func managedView(for target: Window) -> View?
    {
        managedWindows[target.id]
    }

    func removeManagedWindow(_ windowID: WindowID)
    {
        managedWindows.removeValue(forKey: windowID)
    }

    func addManagedWindow(_ target: Window, to owner: View)
    {
        if owner.layout == .float { return }

        if managedWindows[target.id] == nil { managedWindows[target.id] = owner }
        purifyWindow(target)
    }

    //
    // NOTE: These operations on tree spaces act on the container selected with
    // 'window --focus parent' when there is one, and on the window otherwise.
    //

    //
    // NOTE: Unmanaging a window removes it from its view's tree and gives it the shadow and layer of an unmanaged window.
    //

    func unmanageWindow(_ target: Window, from owner: View)
    {
        SpaceManager.shared.untile(target, from: owner)
        removeManagedWindow(target.id)
        purifyWindow(target)
    }

    func manageWindow(_ target: Window, on spaceID: SpaceID, inserting insertionPoint: WindowID?)
    {
        let owner = SpaceManager.shared.tile(target, on: spaceID, insertionPoint: insertionPoint)
        addManagedWindow(target, to: owner)
    }

    func treeView(for target: Window?) -> View?
    {
        guard let target, let owner = managedView(for: target) else { return nil }
        return owner.tree != nil ? owner : nil
    }

    func focusWindow(id windowID: WindowID?)
    {
        guard let windowID else { return }
        if let target = window(for: windowID) {
            focusWithRaise(target)
            setPendingFocus(target.id)
        }
    }
}
