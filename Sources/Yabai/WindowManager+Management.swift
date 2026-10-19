import AppKit
import CoreGraphics
import CPrivate
import YabaiCore

extension WindowManager
{
    // NOTE: Refresh, rule and scratchpad lists remove an item by moving the last element into its slot.

    func applicationRefreshIndex(of application: Application) -> Int?
    {
        applications_to_refresh.firstIndex(of: application)
    }

    func removeApplicationRefresh(at index: Int)
    {
        applications_to_refresh.swapAt(index, applications_to_refresh.count - 1)
        applications_to_refresh.removeLast()
    }

    var applicationRefreshCount: Int { applications_to_refresh.count }

    func applicationRefresh(at index: Int) -> Application
    {
        applications_to_refresh[index]
    }

    func addApplicationToRefresh(_ application: Application)
    {
        applications_to_refresh.append(application)
    }

    var scratchpadCount: Int { scratchpad_window.count }

    func addScratchpad(label: String, window: Window)
    {
        scratchpad_window.append(Scratchpad(label: label, window: window))
    }

    func removeScratchpad(at index: Int)
    {
        scratchpad_window.swapAt(index, scratchpad_window.count - 1)
        scratchpad_window.removeLast()
    }

    func setFocusFollowsMouse(_ mode: FocusFollowsMouse)
    {
        mouse_handler_end(mouse_state_global())

        if mode == .disabled {
            mouse_handler_begin(mouse_state_global(), mouseEventMask)
        } else {
            mouse_handler_begin(mouse_state_global(), mouseEventMaskFFM)
        }

        ffm_mode = mode
    }

    func setWindowOpacityEnabled(_ enabled: Bool)
    {
        enable_window_opacity = enabled
        for target in window.values where target.isEligibleForManagement {
            setOpacity(for: target, to: enabled ? target.opacity : 1.0)
        }
    }

    func centerMouse(on target: Window)
    {
        if !(target.mouseFollowsFocusByRule ?? enable_mff) { return }

        let cursor = SLS.cursorLocation(connection_global())
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
        managed_window[target.id]
    }

    func removeManagedWindow(_ windowID: WindowID)
    {
        managed_window.removeValue(forKey: windowID)
    }

    func addManagedWindow(_ target: Window, to owner: View)
    {
        if owner.layout == .float { return }

        if managed_window[target.id] == nil { managed_window[target.id] = owner }
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
        space_manager_untile_window(owner, target)
        removeManagedWindow(target.id)
        purifyWindow(target)
    }

    func manageWindow(_ target: Window, on spaceID: SpaceID, inserting insertionPoint: WindowID?)
    {
        let owner = space_manager_tile_window_on_space_with_insertion_point(SpaceManager.shared, target, spaceID, insertionPoint)
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
