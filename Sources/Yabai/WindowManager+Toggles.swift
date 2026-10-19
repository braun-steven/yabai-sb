import AppKit
import ApplicationServices
import CoreGraphics
import CoreFoundation
import CPrivate

extension WindowManager
{
    private static var nativeFullscreenWaitIterations: Int { 30 }

    func waitForNativeFullscreenTransition()
    {
        var iteration = 0
        while iteration < Self.nativeFullscreenWaitIterations && !(space_manager_active_space().map(space_is_user) ?? false) {
            // NOTE: A window has left native fullscreen, but its display may still be animating. Keep waiting before
            // interacting with the window. The display manager API does not work for this on macOS Monterey.
            // The wait is bounded because the destination space may never become active, such as after a cancelled
            // transition, and this synchronous wait blocks the event loop.
            usleep(100000)
            iteration += 1
        }
    }

    func toggleNativeFullscreen(_ target: Window)
    {
        let spaceID = target.id.space

        // NOTE: The window must be focused before its fullscreen attribute changes. Focus it and wait for a possible
        // space animation to finish before setting the attribute.
        focusWithRaise(target)
        var iteration = 0
        while iteration < Self.nativeFullscreenWaitIterations && spaceID != space_manager_active_space() {
            usleep(100000)
            iteration += 1
        }

        AXUIElementSetAttributeValue(
            target.ref,
            Window.fullscreenAttribute as CFString,
            target.reportsFullscreen ? kCFBooleanFalse : kCFBooleanTrue
        )

        // NOTE: After changing fullscreen, wait for the display animation to finish.
        waitForNativeFullscreenTransition()
    }

    private func toggleZoom(for target: Window, to zoom: ConZoom)
    {
        guard let owner = treeView(for: target) else { return }
        guard let node = owner.tree?.find(target.id), node != owner.tree else { return }

        var zoom = zoom
        if zoom == .parent && node.parent == owner.tree { zoom = .fullscreen }

        node.zoom = node.zoom == zoom ? .none : zoom
        treeApply(owner)
    }

    func toggleParentZoom(_ target: Window)
    {
        toggleZoom(for: target, to: .parent)
    }

    func toggleFullscreenZoom(_ target: Window)
    {
        toggleZoom(for: target, to: .fullscreen)
    }

    func toggleWindowedFullscreen(_ target: Window)
    {
        guard let displayID = target.id.displayID else { return }

        if target.isWindowed {
            target.isWindowed = false
            let frame = target.windowedFrame
            window_manager_animate_window(window_capture(
                window: target,
                x: Float(frame.origin.x),
                y: Float(frame.origin.y),
                w: Float(frame.size.width),
                h: Float(frame.size.height)
            ))
        } else {
            target.isWindowed = true
            target.windowedFrame = target.frame
            let bounds = display_bounds_constrained(displayID, true)
            window_manager_animate_window(window_capture(
                window: target,
                x: Float(bounds.origin.x),
                y: Float(bounds.origin.y),
                w: Float(bounds.size.width),
                h: Float(bounds.size.height)
            ))
        }
    }

    func toggleExpose(_ target: Window)
    {
        focusWithRaise(target)
        CoreDock.sendNotification("com.apple.expose.front.awake")
    }

    func togglePictureInPicture(_ target: Window)
    {
        guard let displayID = target.id.displayID else { return }

        // NOTE: Without a space on the display, its bounds are not reduced by padding because the space's view has none.
        let view = display_space_id(displayID).map { space_manager_find_view(SpaceManager.shared, $0) }

        var bounds = display_bounds_constrained(displayID, false)
        if let view, view.isPaddingEnabled {
            bounds.origin.x    += CGFloat(view.leftPadding)
            bounds.size.width  -= CGFloat(view.leftPadding + view.rightPadding)
            bounds.origin.y    += CGFloat(view.topPadding)
            bounds.size.height -= CGFloat(view.topPadding + view.bottomPadding)
        }

        scripting_addition_scale_window(
            target.id,
            Float(bounds.origin.x),
            Float(bounds.origin.y),
            Float(bounds.size.width),
            Float(bounds.size.height)
        )
    }
}
