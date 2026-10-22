import ApplicationServices
import CoreGraphics
import Foundation
import CPrivate
import SortedCollections
import YabaiCore

//
// NOTE: The layout, gap and padding commands of spaces, and the tiling of windows into their views.
//

private func addAndClampToZero(_ a: Int, _ b: Int) -> Int
{
    return a + b <= 0 ? 0 : a + b
}

extension SpaceManager
{
    func setLayout(_ layout: ViewType, for sid: SpaceID)
    {
        let target = view(for: sid)
        target.layout = layout
        target.clear()

        if target.layout != .float {
            WindowManager.shared.validateAndCheckForWindows(on: sid)
        }
    }

    func setGap(_ gap: Int, type: ValueType?, for sid: SpaceID) -> Bool
    {
        let target = view(for: sid)
        if target.layout == .float { return false }

        if type == .abs {
            target.windowGap = gap
        } else if type == .rel {
            target.windowGap = addAndClampToZero(target.windowGap, gap)
        }

        target.updateAndFlush()

        return true
    }

    /// Toggles the padding or gap switch of a view.
    private func toggleViewSetting(_ setting: ReferenceWritableKeyPath<View, Bool>, for sid: SpaceID) -> Bool
    {
        let target = view(for: sid)
        if target.layout == .float { return false }

        target[keyPath: setting].toggle()

        target.updateAndFlush()

        return true
    }

    func toggleGap(for sid: SpaceID) -> Bool
    {
        return toggleViewSetting(\.isGapEnabled, for: sid)
    }

    /// The views without their own layout take the layout.
    func setLayoutForAllSpaces(_ layout: ViewType)
    {
        Config.current.space.layout = layout

        for target in views.values {
            if !target.overrides.contains(.layout) {
                if target.sid.isUser {
                    target.layout = layout
                    target.clear()

                    if target.layout != .float {
                        WindowManager.shared.validateAndCheckForWindows(on: target.sid)
                    }
                }
            }
        }
    }

    func setSpacingForAllSpaces(_ spacing: ViewSpacing, to value: Int)
    {
        Config.current.space[keyPath: spacing.spaceDefault] = value

        for target in views.values {
            if !target.overrides.contains(spacing.override) {
                target[keyPath: spacing.view] = value
                target.updateAndFlush()
            }
        }
    }

    private func applyAutoPadding(_ autoPadding: Bool, to target: View)
    {
        if target.autoPadding == autoPadding { return }

        target.autoPadding = autoPadding
        if target.layout == .float { return }

        target.updateAndFlush()
    }

    func setAutoPaddingForAllSpaces(_ autoPadding: Bool)
    {
        Config.current.space.autoPadding = autoPadding

        for target in views.values {
            if !target.overrides.contains(.autoPadding) {
                applyAutoPadding(autoPadding, to: target)
            }
        }
    }

    func setAutoPadding(_ autoPadding: Bool, for sid: SpaceID)
    {
        let target = view(for: sid)
        target.overrides.insert(.autoPadding)
        applyAutoPadding(autoPadding, to: target)
    }

    func setPadding(top: Int, bottom: Int, left: Int, right: Int, type: ValueType?, for sid: SpaceID) -> Bool
    {
        let target = view(for: sid)
        if target.layout == .float { return false }

        if type == .abs {
            target.topPadding     = top
            target.bottomPadding  = bottom
            target.leftPadding    = left
            target.rightPadding   = right
        } else if type == .rel {
            target.topPadding     = addAndClampToZero(target.topPadding, top)
            target.bottomPadding  = addAndClampToZero(target.bottomPadding, bottom)
            target.leftPadding    = addAndClampToZero(target.leftPadding, left)
            target.rightPadding   = addAndClampToZero(target.rightPadding, right)
        }

        target.updateAndFlush()

        return true
    }

    func togglePadding(for sid: SpaceID) -> Bool
    {
        return toggleViewSetting(\.isPaddingEnabled, for: sid)
    }

    /// The view of a space when it is a tree with a root.
    private func treeView(for sid: SpaceID) -> View?
    {
        let target = view(for: sid)
        return target.layout == .tree && target.tree != nil ? target : nil
    }

    func rotateSpace(_ sid: SpaceID, by degrees: Int) -> Bool
    {
        guard let target = treeView(for: sid) else { return false }

        target.tree!.rotate(by: degrees)
        target.updateAndFlush()

        return true
    }

    func mirrorSpace(_ sid: SpaceID, axis: WindowSplit) -> Bool
    {
        guard let target = treeView(for: sid) else { return false }

        target.tree!.mirror(axis == .x ? .vertical : .horizontal)
        target.updateAndFlush()

        return true
    }

    func balanceSpace(_ sid: SpaceID) -> Bool
    {
        guard let target = treeView(for: sid) else { return false }

        target.tree!.balance()
        target.updateAndFlush()

        return true
    }

    func tile(_ win: Window, on sid: SpaceID, insertionPoint: WindowID? = nil) -> View
    {
        let target = view(for: sid)
        if target.layout == .float { return target }

        win.adjustLayer(to: .below)
        target.add(win, insertionPoint: insertionPoint)
        target.flush()

        return target
    }

    func toggleSplit(of win: Window)
    {
        guard let sid = win.id.space else { return }

        let target = view(for: sid)
        if target.layout != .tree { return }

        try? WindowManager.shared.setWindowLayout(win, .toggleSplit)
    }
}
