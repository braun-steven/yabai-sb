import ApplicationServices
import Foundation
import AppKit
import CPrivate
import YabaiCore
import Logging
import Synchronization

//
// NOTE: The handlers of mouse events: moving and resizing windows with the mouse modifier, dropping them on
// other windows, tab bar clicks, and focus follows mouse.
//

//
// NOTE: A resize drags the corner (or edge) of the window that is closest to where the mouse went down.
//

extension ResizeHandle
{
    /// The edges that a resize from point drags: the ones on the side of the frame's center where point is.
    init(at point: CGPoint, in frame: CGRect)
    {
        self.init(rawValue: 0)
        let frameMid = CGPoint(x: frame.midX, y: frame.midY)

        if point.x < frameMid.x { insert(.left) }
        if point.y < frameMid.y { insert(.top) }
        if point.x > frameMid.x { insert(.right) }
        if point.y > frameMid.y { insert(.bottom) }
    }
}

//
// NOTE: Resizing through the AX API is slow, so a drag resizes the window at most once per throttle
// interval. Returns false when this event was skipped.
//

private let mouseResizeThrottleMs: Float = 67.67

extension EventHandler
{
    func mouseDown(_ event: CGEvent, _ modifiers: MouseModifiers)
    {
        let ms = MouseState.shared

        if MissionControl.shared.isActive                 { return }
        if ms.currentAction != .none { return }

        let point = event.location
        Logger.events.debug("mouse down: \(cFormat("%.2f, %.2f", point.x, point.y))")

        guard let window = WindowManager.shared.window(at: point), !window.isFullscreen else { return }

        ms.window = window
        ms.windowFrame = window.frame
        ms.downLocation = point
        ms.direction = []

        let button = event.getIntegerValueField(.mouseEventButtonNumber)

        let config = Config.current.mouse
        if button == Int64(CGMouseButton.left.rawValue) && config.modifier.modifiers == modifiers {
            ms.currentAction = config.action1
        } else if button == Int64(CGMouseButton.right.rawValue) && config.modifier.modifiers == modifiers {
            ms.currentAction = config.action2
        }

        if ms.currentAction == .resize {
            ms.direction = ResizeHandle(at: point, in: ms.windowFrame)
        }
    }

    func tabBarClicked(_ wid: WindowID)
    {
        Logger.events.debug("tab bar clicked: \(wid)")

        guard let window = WindowManager.shared.window(for: wid) else { return }

        WindowManager.shared.focusWithRaise(window)
    }

    func tabCardOrdered(_ wid: WindowID)
    {
        Logger.events.debug("tab card ordered: \(wid)")
        WindowManager.shared.cardDidOrder(wid)
    }

    //
    // NOTE: The view of the space under the cursor, and the window under the cursor other than the dragged
    // window (or nil), that a dragged window is dropped on.
    //

    private func mouseDropTarget(_ point: CGPoint) -> (view: View?, window: Window?)
    {
        let wm = WindowManager.shared
        let ms = MouseState.shared

        let cursorSid = DisplayID(containing: point).flatMap { $0.currentSpace }
        let dstView = cursorSid.map { SpaceManager.shared.view(for: $0) }

        var window = wm.window(at: point, excluding: ms.window.id)
        if window == nil { window = wm.window(at: point) }
        return (dstView, window == ms.window ? nil : window)
    }

    func mouseUp(_ event: CGEvent)
    {
        let wm = WindowManager.shared
        let ms = MouseState.shared

        if MissionControl.shared.isActive { return }

        guard let window = ms.window else {
            ms.currentAction = .none
            return
        }

        defer {
            ms.window = nil
            ms.currentAction = .none
        }

        if !window.isValid {
            Logger.events.debug("mouse up: \(window.id) has been marked invalid by the system, ignoring event")
            return
        }

        if window.isFullscreen {
            Logger.events.debug("mouse up: \(window.id) is transitioning into native-fullscreen mode, ignoring event")
            return
        }

        let point = event.location
        Logger.events.debug("mouse up: \(cFormat("%.2f, %.2f", point.x, point.y))")

        guard let srcView = wm.managedView(for: window) else { return }

        let info = ms.windowChange

        if info.changedPosition && !info.changedSize {
            let target = mouseDropTarget(point)

            ms.drop(window, from: srcView, onto: target.window, in: target.view, at: point)
        } else if info.changedPosition || info.changedSize {
            wm.resizeAfterDrag(window, in: srcView, by: info)
        }
    }

    private func mouseDragMoveWindow(_ point: CGPoint)
    {
        let ms = MouseState.shared

        var newPoint = CGPoint(x: ms.windowFrame.origin.x + (point.x - ms.downLocation.x),
                               y: ms.windowFrame.origin.y + (point.y - ms.downLocation.y))

        let did = DisplayID(containing: newPoint)
        if let did {
            let bounds = did.constrainedBounds(ignoringExternalBar: false)
            if newPoint.y < bounds.origin.y { newPoint.y = bounds.origin.y }
        }

        if !ScriptingAddition.shared.moveWindow(ms.window.id, x: Int32(newPoint.x), y: Int32(newPoint.y)) {
            ms.window.move(to: newPoint)
        }
    }

    private func mouseDragResizeWindow(_ point: CGPoint) -> Bool
    {
        let ms = MouseState.shared

        let eventTime = OSTimer.now
        if OSTimer.milliseconds(from: ms.lastMovedTime, to: eventTime) < mouseResizeThrottleMs { return false }

        let dx = Int(point.x - ms.downLocation.x)
        let dy = Int(point.y - ms.downLocation.y)

        ms.window.resizeRelative(frame: ms.window.frame, direction: ms.direction, dx: Float(dx), dy: Float(dy), animate: false)

        ms.lastMovedTime = eventTime
        ms.downLocation = point
        return true
    }

    func mouseDragged(_ event: CGEvent)
    {
        let ms = MouseState.shared

        //
        // NOTE: Only the most recent drag event matters, because the new frame is computed from the
        // location where the drag started. Skip this one if a newer one is already queued.
        //

        if EventHandler.isStale(pendingMouseDragged) { return }

        if MissionControl.shared.isActive { return }
        guard let window = ms.window else { return }

        if !window.isValid {
            Logger.events.debug("mouse dragged: \(window.id) has been marked invalid by the system, ignoring event")
            ms.window = nil
            ms.currentAction = .none
            return
        }

        let point = event.location
        Logger.events.debug("mouse dragged: \(cFormat("%.2f, %.2f", point.x, point.y))")

        if ms.currentAction == .move {
            mouseDragMoveWindow(point)
        } else if ms.currentAction == .resize {
            if !mouseDragResizeWindow(point) { return }
        }

        if WindowManager.shared.managedView(for: ms.window) == nil { return }

        let info = ms.windowChange

        if info.changedPosition && !info.changedSize {
            let target = mouseDropTarget(point)

            ms.showDropFeedback(view: target.view, window: target.window, at: point)
        }
    }

    //
    // NOTE(asmvik): Look for a window with role AXSheet or AXDrawer
    // and forward focus to it because we are not allowed to focus the main
    // window in these cases.
    //

    private func ffmWindowToFocus(_ window: Window) -> Window
    {
        guard let associatedWindows = SLS.associatedWindows(SLS.connection, window.id) else { return window }

        let wm = WindowManager.shared

        for childWid in associatedWindows {
            guard let child = wm.window(for: childWid) else { continue }

            guard let role = child.ax.role else { continue }

            if role == kAXSheetRole as String || role == kAXDrawerRole as String {
                return child
            }
        }

        return window
    }

    //
    // NOTE(asmvik): If any **floating** window would be fully occluded by
    // autoraising the window below the cursor we do not actually perform the
    // focus change, as it is likely that the user is trying to reach for the
    // smaller window that sits on top of the window we would otherwise raise.
    //

    private func ffmRaiseWouldOccludeFloatingWindow(_ window: Window) -> Bool
    {
        let wm = WindowManager.shared

        guard let sid = SpaceManager.shared.currentSpaceID, let windowIDs = sid.windows(includingMinimized: false) else { return false }

        let level = window.id.level
        let subLevel = window.id.subLevel

        for wid in windowIDs {
            if wid == window.id { break }

            guard let subWindow = wm.window(for: wid) else { continue }

            if !subWindow.isFloating                      { continue }
            if level != subWindow.id.level        { continue }
            if subLevel != subWindow.id.subLevel { continue }

            if window.frame.contains(subWindow.frame) { return true }
        }

        return false
    }

    private func ffmFocusWindow(_ window: Window)
    {
        let wm = WindowManager.shared
        let ms = MouseState.shared

        if window.id == wm.focus.focused { return }
        if !window.isEligibleForManagement { return }

        if focusFollowsMouse == .autofocus {
            let target = ffmWindowToFocus(window)
            WindowManager.shared.focusWithoutRaise(target)
            ms.ffmWindowID = target.id
        } else if focusFollowsMouse == .autoraise {
            if ffmRaiseWouldOccludeFloatingWindow(window) { return }

            WindowManager.shared.focusWithRaise(window)
            ms.ffmWindowID = window.id
        }
    }

    private func ffmFocusDisplayAtPoint(_ point: CGPoint)
    {
        let cursorDid = DisplayID(containing: point)
        if DisplayManager.shared.currentDisplayID == cursorDid { return }
        guard let did = cursorDid else { return }

        let bounds = did.constrainedBounds(ignoringExternalBar: false)
        if !bounds.containsIncludingEdges(point) { return }

        let wid = DisplayManager.shared.focusWindow(at: point)
        if wid == nil { did.activate() }
        MouseState.shared.ffmWindowID = wid
    }

    func mouseMoved(_ event: CGEvent)
    {
        let wm = WindowManager.shared

        if EventHandler.isStale(pendingMouseMoved) { return }

        if focusFollowsMouse == .disabled                     { return }
        if MissionControl.shared.isActive                     { return }
        if MouseState.shared.ffmWindowID != nil { return }

        if pendingGesture.load(ordering: .relaxed) { return }
        let dt = OSTimer.milliseconds(from: lastGestureTime.load(ordering: .relaxed), to: OSTimer.now)
        if dt < 1250.0 { return }

        let point = event.location

        if let window = wm.window(at: point) {
            ffmFocusWindow(window)
        } else {
            ffmFocusDisplayAtPoint(point)
        }
    }
}
