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
            if enable_window_opacity {
                value = target.id == focusedWindowID ? active_window_opacity : normal_window_opacity
            } else {
                value = 1.0
            }
        }

        return scripting_addition_set_opacity(target.id, value, window_opacity_duration)
    }

    func setWindowOpacity(_ target: Window, to opacity: Float)
    {
        if !enable_window_opacity { return }
        if !target.isEligibleForManagement { return }
        if target.opacity != 0.0 { return }

        setOpacity(for: target, to: opacity)
    }

    func setMenuBarOpacity(_ opacity: Float)
    {
        menubar_opacity = opacity
        SLSSetMenuBarInsetAndAlpha(connection_global(), 0, 1, opacity)
    }

    func setActiveWindowOpacity(_ opacity: Float)
    {
        active_window_opacity = opacity
        if let target = focusedWindow { setWindowOpacity(target, to: active_window_opacity) }
    }

    func setNormalWindowOpacity(_ opacity: Float)
    {
        normal_window_opacity = opacity
        for target in window.values {
            if target.id == focusedWindowID { continue }
            if target.isEligibleForManagement {
                setWindowOpacity(target, to: normal_window_opacity)
            }
        }
    }

    func setWindowLayer(_ target: Window, to layer: WindowLayer) -> Bool
    {
        var parentLayer = layer
        var childLayer = layer

        if layer == .auto {
            let below = managedView(for: target) != nil || (scratchpad_below && target.scratchpad != nil)
            parentLayer = below ? .below : .normal
            childLayer = .normal
        }

        // NOTE: Managed windows and scratchpads configured below the normal layer keep child windows at the normal layer.
        target.layer = layer
        let result = scripting_addition_set_layer(target.id, parentLayer.level)
        if !result { return false }

        guard let associated = SLSCopyAssociatedWindows(connection_global(), target.id.rawValue) as? [NSNumber], !associated.isEmpty else { return result }

        var parentList: [WindowID?] = []
        var childList: [WindowID] = []
        for queried in SLS.queryWindows(connection_global(), associated.map { WindowID($0.uint32Value) }).prefix(associated.count) {
            parentList.append(queried.parent)
            childList.append(queried.id)
        }

        for descendant in Self.collectChildWindows(target.id, parents: &parentList, children: childList) {
            scripting_addition_set_layer(descendant, childLayer.level)
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

        if scripting_addition_set_shadow(target.id, shouldHaveShadow) {
            target.hasShadow = shouldHaveShadow
        }
    }
}
