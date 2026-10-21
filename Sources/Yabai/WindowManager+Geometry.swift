import Foundation
import YabaiCore

extension WindowManager
{
    /// The change of length (in points, along a parent of `size`) that gives a container of share `percent` its new
    /// share: `ratio` added to it (rel) or `ratio` itself (abs, or no type), clamped to 0.05…0.95.
    static func ratioDelta(from percent: Float, type: ValueType?, ratio: Float, size: Float) -> Float
    {
        let target = type == .rel ? percent + ratio : ratio
        return (target.clamped(min: 0.05, max: 0.95) - percent) * size
    }

    func adjustWindowRatio(for target: Window, type: ValueType?, ratio: Float) throws(WindowOperationError)
    {
        guard let owner = treeView(for: target) else { throw .invalidSourceView }

        // NOTE: Tabs share their container's area, so resize the tabbed container's ratio, as i3 does.
        var node = treeActingCon(in: owner, for: target)
        while let current = node, let parent = current.parent, parent.layout == .tabbed { node = parent }
        guard let node, let parent = node.parent else { throw .invalidSourceNode }

        let horizontal = parent.layout == .splitH
        let size = horizontal ? parent.area.w : parent.area.h
        let delta = Self.ratioDelta(from: node.percent, type: type, ratio: ratio, size: size)

        if !node.resize(horizontal ? .east : .south, by: delta) &&
           !node.resize(horizontal ? .west : .north, by: -delta) {
            throw .invalidSourceNode
        }

        owner.updateTree()
        owner.flush()
    }

    func moveWindow(_ target: Window, type: ValueType?, dx: Float, dy: Float) throws(WindowOperationError)
    {
        if managedView(for: target) != nil { throw .invalidSourceView }

        var x = dx
        var y = dy
        if type == .rel {
            x += Float(target.frame.origin.x)
            y += Float(target.frame.origin.y)
        }

        animateWindow(WindowPlacement(window: target, x: x, y: y, w: Float(target.frame.size.width), h: Float(target.frame.size.height)))
    }

    func resizeWindow(_ target: Window, direction: ResizeHandle, dx: Float, dy: Float, animate: Bool) throws(WindowOperationError)
    {
        if let owner = managedView(for: target) {
            if direction == .abs || owner.tree == nil { throw .invalidOperation }

            guard let node = treeActingCon(in: owner, for: target) else { throw .invalidSourceNode }

            var didResize = false
            if direction.contains(.top)    { didResize = node.resize(.north, by: dy) || didResize }
            if direction.contains(.bottom) { didResize = node.resize(.south, by: dy) || didResize }
            if direction.contains(.left)   { didResize = node.resize(.west, by: dx) || didResize }
            if direction.contains(.right)  { didResize = node.resize(.east, by: dx) || didResize }
            if !didResize { throw .invalidDestinationNode }

            owner.updateTree()
            owner.flush()
        } else if direction == .abs {
            if animate {
                animateWindow(WindowPlacement(window: target, x: Float(target.frame.origin.x), y: Float(target.frame.origin.y), w: dx, h: dy))
            } else {
                target.application.ref.withEnhancedUserInterfaceDisabled { target.resize(width: dx, height: dy) }
            }
        } else {
            target.resizeRelative(frame: target.axFrame, direction: direction, dx: dx, dy: dy, animate: animate)
        }
    }
}
