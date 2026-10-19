import CPrivate
import YabaiCore

extension WindowManager
{
    func setPurifyMode(_ mode: PurifyMode)
    {
        purifyMode = mode
        for target in window.values where target.isEligibleForManagement {
            purifyWindow(target)
        }
    }

    /// An opacity of zero uses the focus opacity, or 1 when window opacity is disabled.
    @discardableResult
    func setOpacity(for target: Window, to opacity: Float) -> Bool
    {
        var value = opacity
        if value == 0.0 {
            if windowOpacityEnabled {
                value = target.id == focusedWindowID ? activeWindowOpacity : normalWindowOpacity
            } else {
                value = 1.0
            }
        }

        return ScriptingAddition.shared.setOpacity(value, of: target.id, duration: windowOpacityDuration)
    }

    func setWindowOpacity(_ target: Window, to opacity: Float)
    {
        if !windowOpacityEnabled { return }
        if !target.isEligibleForManagement { return }
        if target.opacity != 0.0 { return }

        setOpacity(for: target, to: opacity)
    }

    func setMenuBarOpacity(_ opacity: Float)
    {
        menuBarOpacity = opacity
        SLS.setMenuBarAlpha(SLS.connection, opacity)
    }

    func setActiveWindowOpacity(_ opacity: Float)
    {
        activeWindowOpacity = opacity
        if let target = focusedWindow { setWindowOpacity(target, to: activeWindowOpacity) }
    }

    func setNormalWindowOpacity(_ opacity: Float)
    {
        normalWindowOpacity = opacity
        for target in window.values {
            if target.id == focusedWindowID { continue }
            if target.isEligibleForManagement {
                setWindowOpacity(target, to: normalWindowOpacity)
            }
        }
    }

    func setWindowLayer(_ target: Window, to layer: WindowLayer) -> Bool
    {
        var parentLayer = layer
        var childLayer = layer

        if layer == .auto {
            let below = managedView(for: target) != nil || (scratchpadBelow && target.scratchpad != nil)
            parentLayer = below ? .below : .normal
            childLayer = .normal
        }

        // NOTE: Managed windows and scratchpads configured below the normal layer keep child windows at the normal layer.
        target.layer = layer
        let result = ScriptingAddition.shared.setLayer(parentLayer.level, of: target.id)
        if !result { return false }

        guard let associated = SLS.associatedWindows(SLS.connection, target.id), !associated.isEmpty else { return result }

        var parentList: [WindowID?] = []
        var childList: [WindowID] = []
        for queried in SLS.queryWindows(SLS.connection, associated).prefix(associated.count) {
            parentList.append(queried.parent)
            childList.append(queried.id)
        }

        for descendant in Self.collectChildWindows(target.id, parents: &parentList, children: childList) {
            ScriptingAddition.shared.setLayer(childLayer.level, of: descendant)
        }

        return result
    }

    // NOTE: Each parent-child relation is consumed once during breadth-first traversal, so cycles cannot repeat windows.
    static func collectChildWindows(_ root: WindowID, parents: inout [WindowID?], children: [WindowID]) -> [WindowID]
    {
        var result: [WindowID] = []
        var parent = root
        var next = 0

        while true {
            for index in 0..<parents.count where parents[index] == parent {
                parents[index] = nil
                result.append(children[index])
            }

            if next == result.count { break }
            parent = result[next]
            next += 1
        }

        return result
    }

    func purifyWindow(_ target: Window)
    {
        let shouldHaveShadow: Bool
        switch purifyMode {
        case .disabled: shouldHaveShadow = true
        case .managed:  shouldHaveShadow = managedView(for: target) == nil
        case .always:   shouldHaveShadow = false
        }

        if ScriptingAddition.shared.setShadow(shouldHaveShadow, of: target.id) {
            target.hasShadow = shouldHaveShadow
        }
    }
}
