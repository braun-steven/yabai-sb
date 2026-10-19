import CoreGraphics
import Foundation
import Synchronization
import CPrivate
import AppKit
import YabaiCore

// NOTE: Four inline frames; moves and resizes do not allocate or copy array storage.
struct BorderEdges
{
    var top = CGRect.zero
    var bottom = CGRect.zero
    var left = CGRect.zero
    var right = CGRect.zero

    subscript(_ index: Int) -> CGRect {
        get {
            switch index {
            case 0: return top
            case 1: return bottom
            case 2: return left
            default: return right
            }
        }
        set {
            switch index {
            case 0: top = newValue
            case 1: bottom = newValue
            case 2: left = newValue
            default: right = newValue
            }
        }
    }
}

//
// NOTE: A border is made of four raw SkyLight windows, one per edge, around the window it belongs to. A single
// window around the whole frame would need a backing store as large as the window (about 30 MB at 2x for a big
// window, and the window server keeps one even when the window is only shaped like a ring); the edges only need
// one for the ring itself. The top and bottom edges span the full width and are tall enough to hold the rounded
// corners, the left and right edges fill the straight part in between.
//
// The borders are ordered right below their window, so the window covers the inner edge of the ring, and live on
// the space of their window, so space switches show and hide them without any work from us.
//
// The event loop decides whether a window has a border and which color it has (Border.refresh). Moves and resizes
// are applied directly from the SkyLight notifications on the main thread (Border.windowMoved/windowChanged), without a
// round trip through the event queue, so the border keeps up with a window that is dragged. Both sides only touch
// the border table and its settings below, which are guarded by borderLock, and never the Window objects.
//
final class Border
{
    let wid: WindowID
    var ids: [UInt32] = [0, 0, 0, 0]
    var contexts: [CGContext?] = [nil, nil, nil, nil]
    var edges = BorderEdges()
    var frame = CGRect.zero
    var area = CGRect.zero
    var sid: SpaceID?
    var radius: Float = 0
    var containerRadius: Float = 0
    var drawnRadius: Float = 0
    var insetTop: Float = 0
    var insetLeft: Float = 0
    var insetBottom: Float = 0
    var insetRight: Float = 0
    var width: Float = 0
    var color: UInt32 = 0
    var enabled = false
    var focused = false
    var shown = false
    var sticky = false
    var suspended = false
    var level: Int32 = 0
    var subLevel: Int32 = 0

    fileprivate init(_ wid: WindowID) { self.wid = wid }
}

private struct BorderSettings
{
    var enabled = false
    var width: Float = 0
    var activeColor = RGBAColor()
    var normalColor = RGBAColor()
}

// NOTE: Every access to the reference objects in this state holds borderLock, including the main-thread callbacks.
private struct BorderState: @unchecked Sendable
{
    var borders: [WindowID: Border] = [:]
    var settings = BorderSettings()
    var batchDepth = 0
    var show: [WindowID] = []
    var hide: [WindowID] = []
}
private let borderLock = Mutex(BorderState())

//
// NOTE: Within a batch, borders that are turned on or off are shown and hidden only at its end. The windows of a
// tabbed container share the ring around the container, so a tab switch turns off the border of one tab and turns on
// the same ring for the other. Edges that are ordered in again stay blank for a few frames, so instead of hiding one
// ring and showing the other, the edges of the shown ring are handed over to the new tab (Border.handOver(to:_:)).
//

//
// NOTE: The frame the ring goes around: the bounds of the window, grown by the insets of the container it wraps
// (the tab bars of a tabbed container), and the corner radius of that frame.
//
extension Border
{
    private func targetFrame(_ bounds: CGRect) -> CGRect
    {
        CGRect(x: bounds.minX - CGFloat(insetLeft), y: bounds.minY - CGFloat(insetTop),
               width: bounds.width + CGFloat(insetLeft) + CGFloat(insetRight),
               height: bounds.height + CGFloat(insetTop) + CGFloat(insetBottom))
    }

    private var targetRadius: Float { containerRadius > 0 ? containerRadius : radius }
}

//
// NOTE: Splits the ring around the frame into the frames of the four edge windows. The ring is width wide and its
// outer corners have a radius of radius + width, so the top and bottom edges must be that tall to hold a corner.
// The left and right edges reach one point under the window, like the inner edge of the ring, so that no gap shows
// next to the antialiased edge of the window. For a window too short for two corners, the top and bottom edges
// split the height and the side edges are empty.
//
extension BorderEdges
{
    init(around frame: CGRect, width: Float, radius: Float)
    {
        let outer = frame.insetBy(dx: -CGFloat(width), dy: -CGFloat(width))
        let extent = ceilf(radius + width)
        let topHeight = min(extent, floorf(Float(outer.height * 0.5)))
        let bottomHeight = Float(min(Double(extent), outer.height - Double(topHeight)))
        let sideHeight = Float(max(outer.height - Double(topHeight) - Double(bottomHeight), 0))
        let sideWidth = min(width + 1, floorf(Float(outer.width * 0.5)))
        self.init(top: CGRect(x: outer.minX, y: outer.minY, width: outer.width, height: CGFloat(topHeight)),
                  bottom: CGRect(x: outer.minX, y: outer.minY + outer.height - CGFloat(bottomHeight), width: outer.width, height: CGFloat(bottomHeight)),
                  left: CGRect(x: outer.minX, y: outer.minY + CGFloat(topHeight), width: CGFloat(sideWidth), height: CGFloat(sideHeight)),
                  right: CGRect(x: outer.minX + outer.width - CGFloat(sideWidth), y: outer.minY + CGFloat(topHeight), width: CGFloat(sideWidth), height: CGFloat(sideHeight)))
    }
}

/// The corner radius of a border when the window server reports none for its window.
private let borderDefaultRadius: Float = 9

extension Border
{
    //
    // NOTE: Since macOS 26 windows have different corner radii, which SkyLight reports per window.
    //
    private static func windowRadius(of wid: WindowID) -> Float
    {
        var radius: Int32 = 0
        let windows = [NSNumber(value: Int32(bitPattern: wid.rawValue))] as CFArray
        if let query = SLSWindowQueryWindows(SLS.connection, windows, 1),
           let iterator = SLSWindowQueryResultCopyWindows(query), SLSWindowIteratorAdvance(iterator),
           let radii = SLSWindowIteratorGetCornerRadii(iterator), CFArrayGetCount(radii) > 0 {
            let number = unsafeBitCast(CFArrayGetValueAtIndex(radii, 0), to: CFNumber.self)
            CFNumberGetValue(number, .intType, &radius)
        }
        return radius > 0 ? Float(radius) : borderDefaultRadius
    }

    private func createEdge(_ index: Int)
    {
        let edge = edges[index]
        var shape = CGRect(x: 0, y: 0, width: max(edge.width, 1), height: max(edge.height, 1))
        //
        // NOTE: Created with SLSNewWindow instead of SLSNewWindowWithOpaqueShapeAndContext like the tab bars, because a
        // window of the latter is moved to the active space each time it is ordered in again, so a border that was hidden
        // and shown again would land on whatever space is visible instead of the space of its window.
        //
        var region: CFTypeRef?
        CGSNewRegionWithRect(&shape, &region)
        let shapeRegion = region!
        SLSNewWindow(SLS.connection, 2, Float(edge.minX), Float(edge.minY), shapeRegion, &ids[index])
        var tags: UInt64 = (1 << 1) | (1 << 9)
        SLSSetWindowTags(SLS.connection, ids[index], &tags, 64)
        SLS.disableShadow(ids[index])
        SLSSetWindowResolution(SLS.connection, ids[index], 2)
        SLSSetWindowOpacity(SLS.connection, ids[index], false)
        contexts[index] = SLWindowContextCreate(SLS.connection, ids[index], nil)
    }

    private func reshapeEdge(_ index: Int)
    {
        let edge = edges[index]
        var shape = CGRect(x: 0, y: 0, width: max(edge.width, 1), height: max(edge.height, 1))
        var region: CFTypeRef?
        CGSNewRegionWithRect(&shape, &region)
        let shapeRegion = region!
        SLSSetWindowShape(SLS.connection, ids[index], Float(edge.minX), Float(edge.minY), shapeRegion)
    }

    //
    // NOTE: Every edge draws the whole ring, shifted so that its own part of the ring lands in its bounds; the context
    // clips the rest. The ring is the area between the outer rounded rect and the window frame inset by one point,
    // filled with the even-odd rule.
    //
    private func drawEdge(_ index: Int, _ color: RGBAColor)
    {
        guard let context = contexts[index] else { return }
        let edge = edges[index]
        context.clear(CGRect(origin: .zero, size: edge.size))
        let outer = frame.insetBy(dx: -CGFloat(width), dy: -CGFloat(width))
        let ring = CGRect(origin: .zero, size: outer.size)
        let inner = ring.insetBy(dx: CGFloat(width + 1), dy: CGFloat(width + 1))
        let cornerRadius = targetRadius
        let outerRadius = Float(min(Double(cornerRadius + width), min(ring.width, ring.height) * 0.5))
        let innerRadius = Float(min(Double(cornerRadius), min(inner.width, inner.height) * 0.5))
        context.saveGState()
        context.translateBy(x: outer.minX - edge.minX, y: (edge.minY + edge.height) - (outer.minY + outer.height))
        let path = CGMutablePath()
        path.addRoundedRect(in: ring, cornerWidth: CGFloat(outerRadius), cornerHeight: CGFloat(outerRadius))
        if inner.width > 0 && inner.height > 0 {
            path.addRoundedRect(in: inner, cornerWidth: CGFloat(max(innerRadius, 0)), cornerHeight: CGFloat(max(innerRadius, 0)))
        }
        context.setFillColor(red: CGFloat(color.r), green: CGFloat(color.g), blue: CGFloat(color.b), alpha: CGFloat(color.a))
        context.addPath(path)
        context.drawPath(using: .eoFill)
        context.restoreGState()
        context.flush()
    }
}

extension Border
{
    private func hide()
    {
        if !shown { return }
        for id in ids where id != 0 { SLSOrderWindow(SLS.connection, id, 0, 0) }
        shown = false
    }

    private func release()
    {
        hide()
        for i in 0..<4 {
            contexts[i] = nil
            if ids[i] != 0 { SLSReleaseWindow(SLS.connection, ids[i]) }
            ids[i] = 0
        }
    }

    private func move(to sid: SpaceID)
    {
        let windows = ids.map { NSNumber(value: Int32(bitPattern: $0)) } as CFArray
        SLSMoveWindowsToManagedSpace(SLS.connection, windows, sid.rawValue)
        self.sid = sid
    }

    private func setSticky(_ sticky: Bool)
    {
        if self.sticky == sticky { return }
        var tags: UInt64 = 1 << 11
        for id in ids {
            if sticky { SLSSetWindowTags(SLS.connection, id, &tags, 64) }
            else { SLSClearWindowTags(SLS.connection, id, &tags, 64) }
        }
        self.sticky = sticky
    }
}

//
// NOTE: Brings the border in line with its window. The frame update moves the edges to the frame of the window and
// reshapes and redraws them when its size or the color changed. The order update hides the border while the window
// is not ordered in, otherwise orders the edges right below the window at its level and keeps them on its space.
// A border that is shown again gets both. Updates are pushed by the window server notifications of the window, so
// each one does only what its notification can have changed: SkyLight calls are cheap, but yabai makes many of them.
//
// The color update only redraws the edges of a shown border in its current color, without asking the window server
// about the window. A focus change needs nothing else, and it happens while the application of the window is busy
// becoming active: the window server can hold back its replies about the window until then, for up to half a second.
//
private struct BorderUpdate: OptionSet
{
    let rawValue: Int

    static let frame = BorderUpdate(rawValue: 1)
    static let order = BorderUpdate(rawValue: 2)
    static let color = BorderUpdate(rawValue: 4)
    static let frameAndOrder: BorderUpdate = [.frame, .order]
}

extension Border
{
    private func currentColor(_ settings: BorderSettings) -> RGBAColor
    {
        focused ? settings.activeColor : settings.normalColor
    }

    //
    // NOTE: Returns false when the window has no bounds anymore, so the border has to be hidden.
    //
    private func updateFrameLocked(_ settings: BorderSettings) -> Bool
    {
        guard let bounds = SLS.windowBounds(SLS.connection, wid) else { return false }
        let newFrame = targetFrame(bounds)
        let newRadius = targetRadius
        let newColor = currentColor(settings)
        let restyled = width != settings.width || newRadius != drawnRadius || newColor.argb != color
        let previous = edges
        frame = newFrame
        width = settings.width
        drawnRadius = newRadius
        color = newColor.argb
        edges = BorderEdges(around: newFrame, width: width, radius: newRadius)
        let created = ids[0] == 0
        if created {
            for i in 0..<4 { createEdge(i) }
            sid = nil
            sticky = false
            level = .min
            subLevel = .min
        }
        //
        // NOTE: Only edges whose size changed are reshaped and redrawn: a window that gets wider only changes the top
        // and bottom edges, the side edges just move.
        //
        var reshaped = (false, false, false, false)
        var anyReshaped = false
        withUnsafeMutableBytes(of: &reshaped) { raw in
            let list = raw.bindMemory(to: Bool.self)
            for i in 0..<4 {
                list[i] = created || previous[i].size != edges[i].size
                anyReshaped = anyReshaped || list[i]
            }
        }
        if anyReshaped { SLSDisableUpdate(SLS.connection) }
        withUnsafeBytes(of: reshaped) { raw in
            let list = raw.bindMemory(to: Bool.self)
            for i in 0..<4 {
                if list[i] && !created { reshapeEdge(i) }
                if list[i] || restyled { drawEdge(i, newColor) }
                SLSMoveWindow(SLS.connection, ids[i], &edges[i].origin)
            }
        }
        if anyReshaped { SLSReenableUpdate(SLS.connection) }
        return true
    }
}

extension Border
{
    private func updateOrderLocked()
    {
        let windowLevel = wid.level
        let windowSubLevel = wid.subLevel
        for i in 0..<4 {
            if windowLevel != level { SLSSetWindowLevel(SLS.connection, ids[i], windowLevel) }
            if windowSubLevel != subLevel { SLSSetWindowSubLevel(SLS.connection, ids[i], windowSubLevel) }
            //
            // NOTE: A side edge of a window shorter than two corners is empty, so it stays hidden.
            //
            if edges[i].width > 0 && edges[i].height > 0 { SLSOrderWindow(SLS.connection, ids[i], -1, wid.rawValue) }
            else { SLSOrderWindow(SLS.connection, ids[i], 0, 0) }
        }
        level = windowLevel
        subLevel = windowSubLevel
        //
        // NOTE: The edges are put on the space of the window after they are ordered, because ordering them in can
        // move them to the active space.
        //
        let windowSticky = wid.isSticky
        let space = wid.space
        if !windowSticky, let space, WindowID(ids[0]).space != space { move(to: space) }
        if let space { sid = space }
        setSticky(windowSticky)
    }

    private func updateLocked(_ what: BorderUpdate, _ settings: BorderSettings)
    {
        if !settings.enabled || !enabled || suspended { hide(); return }
        let what = shown ? what : .frameAndOrder
        if what == .color {
            let newColor = currentColor(settings)
            for i in 0..<4 { drawEdge(i, newColor) }
            color = newColor.argb
            return
        }
        if what.contains(.order) && !SLS.windowIsOrderedIn(SLS.connection, wid) { hide(); return }
        if what.contains(.frame) && !updateFrameLocked(settings) { hide(); return }
        if what.contains(.order) { updateOrderLocked() }
        shown = true
    }

    //
    // NOTE: Gives the shown edges of this border to the border to, which goes around the same frame, and the hidden
    // edges of to to this border. The edges stay ordered in and are only moved below the window of to, which shares the
    // level and the space of the window of this border, and redrawn when the color differs, all within one update of
    // the screen.
    //
    private func handOver(to target: Border, _ settings: BorderSettings)
    {
        swap(&ids, &target.ids)
        swap(&contexts, &target.contexts)
        swap(&edges, &target.edges)
        swap(&frame, &target.frame)
        swap(&sid, &target.sid)
        swap(&drawnRadius, &target.drawnRadius)
        swap(&width, &target.width)
        swap(&color, &target.color)
        swap(&sticky, &target.sticky)
        swap(&level, &target.level)
        swap(&subLevel, &target.subLevel)
        target.shown = true
        shown = false
        SLSDisableUpdate(SLS.connection)
        target.updateLocked(.frame, settings)
        if target.shown {
            for i in 0..<4 where target.edges[i].width > 0 && target.edges[i].height > 0 { SLSOrderWindow(SLS.connection, target.ids[i], -1, target.wid.rawValue) }
        }
        SLSReenableUpdate(SLS.connection)
    }
}

extension Border
{
    private static func shouldShow(_ target: Window) -> Bool
    {
        if !target.isEligible { return false }
        guard let app = target.application, !app.isHidden else { return false }
        if target.isMinimized { return false }
        if target.isFullscreen { return false }
        if target.isManagedByRule { return true }
        return target.isStandard && target.isStandardLevel
    }

    //
    // NOTE: The number of windows that count for windowBorderHideSingle on a space: the tiled windows, where a tabbed
    // container contributes the visible windows of its active tab, and the visible floating windows. Scratchpads do not count.
    //
    private static func windowCount(on sid: SpaceID?) -> Int
    {
        var count = 0
        if let sid {
            let owner = SpaceManager.shared.view(for: sid)
            count = owner.layout == .tree ? owner.tree?.visibleWindowCount() ?? 0 : 0
        }
        for target in WindowManager.shared.window.values {
            if target.scratchpad != nil || !shouldShow(target) { continue }
            if WindowManager.shared.managedView(for: target) != nil { continue }
            if target.id.space != sid { continue }
            if SLS.windowIsOrderedIn(SLS.connection, target.id) { count += 1 }
        }
        return count
    }

    /// Refreshes the border of a window; count is the windowCount(on:) of its space, nil when it still has to be counted.
    private static func refresh(_ target: Window?, space sid: SpaceID?, windowCount count: Int?)
    {
        guard let target, !target.isDestroyed else { return }
        let wm = WindowManager.shared
        let owner = wm.managedView(for: target)
        let border = owner?.borderArea(windowID: target.id) ?? (visible: true, window: Area.zero, border: Area.zero, radius: 0)
        let windowArea = border.window
        let borderArea = border.border
        let containerRadius = border.radius
        var enabled = wm.windowBorderEnabled && shouldShow(target) && border.visible
        if enabled && wm.windowBorderHideSingle && owner != nil && target.scratchpad == nil {
            let spaceCount = count ?? windowCount(on: sid ?? target.id.space)
            enabled = spaceCount > 1
        }
        let focused = wm.focusedWindowID == target.id
        borderLock.withLock { state in
            state.settings.enabled = wm.windowBorderEnabled
            state.settings.width = wm.windowBorderWidth
            state.settings.activeColor = wm.activeWindowBorderColor
            state.settings.normalColor = wm.normalWindowBorderColor
            if state.borders[target.id] == nil && enabled {
                let border = Border(target.id)
                border.radius = windowRadius(of: target.id)
                state.borders[border.wid] = border
            }
            guard let border = state.borders[target.id] else { return }
            let top = enabled ? windowArea.y - borderArea.y : border.insetTop
            let left = enabled ? windowArea.x - borderArea.x : border.insetLeft
            let bottom = enabled ? (borderArea.y + borderArea.h) - (windowArea.y + windowArea.h) : border.insetBottom
            let right = enabled ? (borderArea.x + borderArea.w) - (windowArea.x + windowArea.w) : border.insetRight
            let radius = enabled ? Float(containerRadius) : border.containerRadius
            let area = enabled ? CGRect(x: CGFloat(borderArea.x), y: CGFloat(borderArea.y), width: CGFloat(borderArea.w), height: CGFloat(borderArea.h)) : border.area
            //
            // NOTE: Nothing to do when the state of the border is unchanged; moves and resizes of the window reach the
            // border through its own notifications. A border that only changes its color is just redrawn.
            //
            let color = focused ? state.settings.activeColor : state.settings.normalColor
            let recolored = border.color != color.argb
            let changed = border.enabled != enabled || border.insetTop != top || border.insetLeft != left || border.insetBottom != bottom || border.insetRight != right || border.containerRadius != radius || border.width != state.settings.width || border.shown != enabled
            border.enabled = enabled
            border.focused = focused
            border.insetTop = top
            border.insetLeft = left
            border.insetBottom = bottom
            border.insetRight = right
            border.containerRadius = radius
            border.area = area
            if changed && !enabled && border.shown && state.batchDepth > 0 && state.hide.count < 64 { state.hide.append(border.wid) }
            else if changed && enabled && !border.shown && state.batchDepth > 0 && state.show.count < 64 { state.show.append(border.wid) }
            else if changed { border.updateLocked(.frameAndOrder, state.settings) }
            else if recolored { border.updateLocked(.color, state.settings) }
        }
    }

    static func beginBatch() { borderLock.withLock { $0.batchDepth += 1 } }

    static func endBatch()
    {
        borderLock.withLock { state in
            state.batchDepth -= 1
            if state.batchDepth > 0 { return }
            for wid in state.show {
                guard let border = state.borders[wid], border.enabled, !border.shown else { continue }
                var shown: Border?
                if state.settings.enabled && !border.suspended && border.area.width > 0 {
                    for otherID in state.hide {
                        if let other = state.borders[otherID], !other.enabled && other.shown && other.area == border.area { shown = other; break }
                    }
                }
                if let shown { shown.handOver(to: border, state.settings) }
                else { border.updateLocked(.frameAndOrder, state.settings) }
            }
            for wid in state.hide {
                if let border = state.borders[wid], !border.enabled { border.hide() }
            }
            state.show.removeAll(keepingCapacity: true)
            state.hide.removeAll(keepingCapacity: true)
        }
    }

    //
    // NOTE: Called on the event loop whenever the state of the window that decides about its border may have changed,
    // e.g. its focus. Changes that can also affect the borders of the other windows on the space (a window appears or
    // disappears, a container changes) refresh the whole space instead.
    //
    static func refresh(_ target: Window?) { refresh(target, space: nil, windowCount: nil) }

    //
    // NOTE: Without windowBorderHideSingle a change on a space only affects the borders of its tiled windows and of
    // the windows that had a border there (e.g. a window that just stopped being tiled), so only those are refreshed,
    // without asking the window server for the space of every window.
    //
    static func refresh(space sid: SpaceID?)
    {
        guard let sid else { return }
        beginBatch()
        defer { endBatch() }
        if WindowManager.shared.windowBorderHideSingle {
            let count = windowCount(on: sid)
            for target in WindowManager.shared.window.values where target.id.space == sid { refresh(target, space: sid, windowCount: count) }
            return
        }
        var windows: [WindowID] = []
        let owner = SpaceManager.shared.view(for: sid)
        if owner.layout == .tree { windows = owner.windowIDs }
        let capacity = windows.count + WindowManager.shared.window.count
        borderLock.withLock { state in
            for border in state.borders.values where border.sid == sid {
                if !windows.contains(border.wid) && windows.count < capacity { windows.append(border.wid) }
            }
        }
        for wid in windows { refresh(WindowManager.shared.window(for: wid), space: sid, windowCount: 0) }
    }

    static func refreshSpace(of target: Window?)
    {
        guard let target, !target.isDestroyed else { return }
        let sid = target.id.space
        if WindowManager.shared.windowBorderHideSingle, let sid { refresh(space: sid) }
        else { refresh(target) }
    }

    static func refreshAll()
    {
        var counts: [SpaceID: Int] = [:]
        for target in WindowManager.shared.window.values {
            let sid = target.id.space
            var count: Int?
            if WindowManager.shared.windowBorderHideSingle, let sid {
                count = counts[sid]
                if count == nil {
                    let spaceCount = windowCount(on: sid)
                    if counts.count < 64 { counts[sid] = spaceCount }
                    count = spaceCount
                }
            }
            refresh(target, space: sid, windowCount: count)
        }
    }

    static func remove(_ wid: WindowID)
    {
        borderLock.withLock { state in
            if let border = state.borders.removeValue(forKey: wid) { border.release() }
        }
    }

    //
    // NOTE: A window that is animated is drawn by a proxy window in its place while the real window already sits at its
    // final frame, so its border is hidden for the duration of the animation and put back at the end.
    //
    static func setSuspended(_ suspended: Bool, for wid: WindowID)
    {
        borderLock.withLock { state in
            if let border = state.borders[wid] {
                border.suspended = suspended
                border.updateLocked(.frameAndOrder, state.settings)
            }
        }
    }

    //
    // NOTE: The handlers below run on the main thread, straight from the SkyLight notifications of the window.
    //
    static func windowMoved(_ wid: WindowID)
    {
        borderLock.withLock { state in
            guard let border = state.borders[wid], border.shown, let bounds = SLS.windowBounds(SLS.connection, wid) else { return }
            let newFrame = border.targetFrame(bounds)
            if newFrame.size != border.frame.size { border.updateLocked(.frame, state.settings); return }
            border.frame = newFrame
            border.edges = BorderEdges(around: newFrame, width: border.width, radius: border.drawnRadius)
            for i in 0..<4 { SLSMoveWindow(SLS.connection, border.ids[i], &border.edges[i].origin) }
        }
    }

    private static func windowUpdate(_ wid: WindowID, _ what: BorderUpdate)
    {
        borderLock.withLock { state in
            if let border = state.borders[wid], border.enabled { border.updateLocked(what, state.settings) }
        }
    }

    static func windowResized(_ wid: WindowID) { windowUpdate(wid, .frame) }
    static func windowOrdered(_ wid: WindowID) { windowUpdate(wid, .order) }
    static func windowChanged(_ wid: WindowID) { windowUpdate(wid, .frameAndOrder) }
    static func windowHidden(_ wid: WindowID)
    {
        borderLock.withLock { state in
            if let border = state.borders[wid] { border.hide() }
        }
    }
}
