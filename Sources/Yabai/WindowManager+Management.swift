import AppKit
import CoreGraphics
import CPrivate
import YabaiCore

extension WindowManager
{
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
