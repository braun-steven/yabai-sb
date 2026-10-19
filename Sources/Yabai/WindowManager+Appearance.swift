import CPrivate
import YabaiCore

extension WindowManager
{
    //
    //
    // NOTE: Apply a set of the opacity and shadow config (from ConfigObserver), as the config setters did.
    //

    func applyOpacityEnabled()
    {
        let enabled = Config.current.opacity.enabled
        for target in window.values where target.isEligibleForManagement {
            setOpacity(for: target, to: enabled ? target.opacity : 1.0)
        }
    }

    func applyWindowOpacity()
    {
        let config = Config.current.windowOpacity
        if let target = focusedWindow { setWindowOpacity(target, to: config.active) }
        for target in window.values where target.id != focusedWindowID && target.isEligibleForManagement {
            setWindowOpacity(target, to: config.normal)
        }
    }

    func applyShadows()
    {
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
            if Config.current.opacity.enabled {
                let config = Config.current.windowOpacity
                value = target.id == focusedWindowID ? config.active : config.normal
            } else {
                value = 1.0
            }
        }

        return ScriptingAddition.shared.setOpacity(value, of: target.id, duration: Config.current.window.opacityDuration)
    }

    func setWindowOpacity(_ target: Window, to opacity: Float)
    {
        if !Config.current.opacity.enabled { return }
        if !target.isEligibleForManagement { return }
        if target.opacity != 0.0 { return }

        setOpacity(for: target, to: opacity)
    }

    func setWindowLayer(_ target: Window, to layer: WindowLayer) -> Bool
    {
        var parentLayer = layer
        var childLayer = layer

        if layer == .auto {
            let below = managedView(for: target) != nil || (Config.current.scratchpad.below && target.scratchpad != nil)
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
        switch Config.current.shadow.mode {
        case .disabled: shouldHaveShadow = true
        case .managed:  shouldHaveShadow = managedView(for: target) == nil
        case .always:   shouldHaveShadow = false
        }

        if ScriptingAddition.shared.setShadow(shouldHaveShadow, of: target.id) {
            target.hasShadow = shouldHaveShadow
        }
    }
}
