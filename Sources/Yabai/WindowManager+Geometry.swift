import Foundation
import YabaiCore

extension WindowManager
{
    func adjustWindowRatio(for target: Window, type: ValueType?, ratio: Float) -> WindowOperationResult
    {
        guard let owner = treeView(for: target) else { return .invalidSourceView }

        // NOTE: Tabs share their container's area, so resize the tabbed container's ratio, as i3 does.
        var node = treeActingCon(in: owner, for: target)
        while let current = node, let parent = current.parent, parent.layout == .tabbed { node = parent }
        guard let node, let parent = node.parent else { return .invalidSourceNode }

        let horizontal = parent.layout == .splitH
        let size = horizontal ? parent.area.w : parent.area.h
        let percent = type == .rel ? node.percent + ratio : ratio
        let delta = (clampf_range(percent, 0.05, 0.95) - node.percent) * size

        if !node.resize(horizontal ? .east : .south, by: delta) &&
           !node.resize(horizontal ? .west : .north, by: -delta) {
            return .invalidSourceNode
        }

        owner.updateTree()
        owner.flush()
        return .success
    }

    func moveWindow(_ target: Window, type: ValueType?, dx: Float, dy: Float) -> WindowOperationResult
    {
        if managedView(for: target) != nil { return .invalidSourceView }

        var x = dx
        var y = dy
        if type == .rel {
            x += Float(target.frame.origin.x)
            y += Float(target.frame.origin.y)
        }

        window_manager_animate_window(window_capture(window: target, x: x, y: y, w: Float(target.frame.size.width), h: Float(target.frame.size.height)))
        return .success
    }

    func resizeWindow(_ target: Window, direction: ResizeHandle, dx: Float, dy: Float, animate: Bool) -> WindowOperationResult
    {
        if let owner = managedView(for: target) {
            if direction == .abs || owner.tree == nil { return .invalidOperation }

            guard let node = treeActingCon(in: owner, for: target) else { return .invalidSourceNode }

            var didResize = false
            if direction.contains(.top)    { didResize = node.resize(.north, by: dy) || didResize }
            if direction.contains(.bottom) { didResize = node.resize(.south, by: dy) || didResize }
            if direction.contains(.left)   { didResize = node.resize(.west, by: dx) || didResize }
            if direction.contains(.right)  { didResize = node.resize(.east, by: dx) || didResize }
            if !didResize { return .invalidDestinationNode }

            owner.updateTree()
            owner.flush()
        } else if direction == .abs {
            if animate {
                window_manager_animate_window(window_capture(window: target, x: Float(target.frame.origin.x), y: Float(target.frame.origin.y), w: dx, h: dy))
            } else {
                axEnhancedUIWorkaround(target.application.ref) { target.resize(width: dx, height: dy) }
            }
        } else {
            target.resizeRelative(frame: target.axFrame, direction: direction, dx: dx, dy: dy, animate: animate)
        }

        return .success
    }
}
