import CoreGraphics
import Foundation
import Synchronization
import CPrivate
import AppKit
import YabaiCore

// NOTE: Four inline frames, like the C array; moves and resizes do not allocate or copy array storage.
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
// The event loop decides whether a window has a border and which color it has (border_refresh). Moves and resizes
// are applied directly from the SkyLight notifications on the main thread (border_window_moved/changed), without a
// round trip through the event queue, so the border keeps up with a window that is dragged. Both sides only touch
// the border table and its settings below, which are guarded by borderLock, and never the window structs.
//
private final class Border
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

    init(_ wid: WindowID) { self.wid = wid }
}

private struct BorderSettings
{
    var enabled = false
    var width: Float = 0
    var activeColor = rgba_color()
    var normalColor = rgba_color()
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
// ring and showing the other, the edges of the shown ring are handed over to the new tab (borderHandOver).
//

//
// NOTE: The frame the ring goes around: the bounds of the window, grown by the insets of the container it wraps
// (the tab bars of a tabbed container), and the corner radius of that frame.
//
private func borderTargetFrame(_ border: Border, _ bounds: CGRect) -> CGRect
{
    CGRect(x: bounds.minX - CGFloat(border.insetLeft), y: bounds.minY - CGFloat(border.insetTop),
           width: bounds.width + CGFloat(border.insetLeft) + CGFloat(border.insetRight),
           height: bounds.height + CGFloat(border.insetTop) + CGFloat(border.insetBottom))
}

private func borderTargetRadius(_ border: Border) -> Float { border.containerRadius > 0 ? border.containerRadius : border.radius }

//
// NOTE: Splits the ring around the frame into the frames of the four edge windows. The ring is width wide and its
// outer corners have a radius of radius + width, so the top and bottom edges must be that tall to hold a corner.
// The left and right edges reach one point under the window, like the inner edge of the ring, so that no gap shows
// next to the antialiased edge of the window. For a window too short for two corners, the top and bottom edges
// split the height and the side edges are empty.
//
func borderEdgeFrames(_ frame: CGRect, _ width: Float, _ radius: Float) -> BorderEdges
{
    let outer = frame.insetBy(dx: -CGFloat(width), dy: -CGFloat(width))
    let extent = ceilf(radius + width)
    let topHeight = min(extent, floorf(Float(outer.height * 0.5)))
    let bottomHeight = Float(min(Double(extent), outer.height - Double(topHeight)))
    let sideHeight = Float(max(outer.height - Double(topHeight) - Double(bottomHeight), 0))
    let sideWidth = min(width + 1, floorf(Float(outer.width * 0.5)))
    return BorderEdges(top: CGRect(x: outer.minX, y: outer.minY, width: outer.width, height: CGFloat(topHeight)),
                       bottom: CGRect(x: outer.minX, y: outer.minY + outer.height - CGFloat(bottomHeight), width: outer.width, height: CGFloat(bottomHeight)),
                       left: CGRect(x: outer.minX, y: outer.minY + CGFloat(topHeight), width: CGFloat(sideWidth), height: CGFloat(sideHeight)),
                       right: CGRect(x: outer.minX + outer.width - CGFloat(sideWidth), y: outer.minY + CGFloat(topHeight), width: CGFloat(sideWidth), height: CGFloat(sideHeight)))
}

func border_edge_frames(_ frame: CGRect, _ width: Float, _ radius: Float, _ edge: UnsafeMutablePointer<CGRect>!)
{
    let frames = borderEdgeFrames(frame, width, radius)
    for i in 0..<4 { edge[i] = frames[i] }
}

//
// NOTE: Since macOS 26 windows have different corner radii, which SkyLight reports per window.
//
private func borderWindowRadius(_ wid: WindowID) -> Float
{
    var radius: Int32 = 0
    let windows = [NSNumber(value: Int32(bitPattern: wid.rawValue))] as CFArray
    if let query = SLSWindowQueryWindows(connection_global(), windows, 1),
       let iterator = SLSWindowQueryResultCopyWindows(query), SLSWindowIteratorAdvance(iterator),
       let radii = SLSWindowIteratorGetCornerRadii(iterator), CFArrayGetCount(radii) > 0 {
        let number = unsafeBitCast(CFArrayGetValueAtIndex(radii, 0), to: CFNumber.self)
        CFNumberGetValue(number, .intType, &radius)
    }
    return radius > 0 ? Float(radius) : borderDefaultRadius
}

/// The corner radius of a border when the window server reports none for its window.
private let borderDefaultRadius: Float = 9

private func borderCreateEdge(_ border: Border, _ index: Int)
{
    let frame = border.edges[index]
    var shape = CGRect(x: 0, y: 0, width: max(frame.width, 1), height: max(frame.height, 1))
    //
    // NOTE: Created with SLSNewWindow instead of SLSNewWindowWithOpaqueShapeAndContext like the tab bars, because a
    // window of the latter is moved to the active space each time it is ordered in again, so a border that was hidden
    // and shown again would land on whatever space is visible instead of the space of its window.
    //
    var region: CFTypeRef?
    CGSNewRegionWithRect(&shape, &region)
    let shapeRegion = region!
    SLSNewWindow(connection_global(), 2, Float(frame.minX), Float(frame.minY), shapeRegion, &border.ids[index])
    var tags: UInt64 = (1 << 1) | (1 << 9)
    SLSSetWindowTags(connection_global(), border.ids[index], &tags, 64)
    sls_window_disable_shadow(border.ids[index])
    SLSSetWindowResolution(connection_global(), border.ids[index], 2)
    SLSSetWindowOpacity(connection_global(), border.ids[index], false)
    border.contexts[index] = SLWindowContextCreate(connection_global(), border.ids[index], nil)
}

private func borderReshapeEdge(_ border: Border, _ index: Int)
{
    let frame = border.edges[index]
    var shape = CGRect(x: 0, y: 0, width: max(frame.width, 1), height: max(frame.height, 1))
    var region: CFTypeRef?
    CGSNewRegionWithRect(&shape, &region)
    let shapeRegion = region!
    SLSSetWindowShape(connection_global(), border.ids[index], Float(frame.minX), Float(frame.minY), shapeRegion)
}

//
// NOTE: Every edge draws the whole ring, shifted so that its own part of the ring lands in its bounds; the context
// clips the rest. The ring is the area between the outer rounded rect and the window frame inset by one point,
// filled with the even-odd rule.
//
private func borderDrawEdge(_ border: Border, _ index: Int, _ color: rgba_color)
{
    guard let context = border.contexts[index] else { return }
    let edge = border.edges[index]
    context.clear(CGRect(origin: .zero, size: edge.size))
    let outer = border.frame.insetBy(dx: -CGFloat(border.width), dy: -CGFloat(border.width))
    let ring = CGRect(origin: .zero, size: outer.size)
    let inner = ring.insetBy(dx: CGFloat(border.width + 1), dy: CGFloat(border.width + 1))
    let radius = borderTargetRadius(border)
    let outerRadius = Float(min(Double(radius + border.width), min(ring.width, ring.height) * 0.5))
    let innerRadius = Float(min(Double(radius), min(inner.width, inner.height) * 0.5))
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

private func borderHide(_ border: Border)
{
    if !border.shown { return }
    for id in border.ids where id != 0 { SLSOrderWindow(connection_global(), id, 0, 0) }
    border.shown = false
}

private func borderRelease(_ border: Border)
{
    borderHide(border)
    for i in 0..<4 {
        border.contexts[i] = nil
        if border.ids[i] != 0 { SLSReleaseWindow(connection_global(), border.ids[i]) }
        border.ids[i] = 0
    }
}

private func borderMoveToSpace(_ border: Border, _ sid: SpaceID)
{
    let windows = border.ids.map { NSNumber(value: Int32(bitPattern: $0)) } as CFArray
    SLSMoveWindowsToManagedSpace(connection_global(), windows, sid.rawValue)
    border.sid = sid
}

private func borderSetSticky(_ border: Border, _ sticky: Bool)
{
    if border.sticky == sticky { return }
    var tags: UInt64 = 1 << 11
    for id in border.ids {
        if sticky { SLSSetWindowTags(connection_global(), id, &tags, 64) }
        else { SLSClearWindowTags(connection_global(), id, &tags, 64) }
    }
    border.sticky = sticky
}

//
// NOTE: Brings the border in line with its window. BORDER_UPDATE_FRAME moves the edges to the frame of the window and
// reshapes and redraws them when its size or the color changed. BORDER_UPDATE_ORDER hides the border while the window
// is not ordered in, otherwise orders the edges right below the window at its level and keeps them on its space.
// A border that is shown again gets both. Updates are pushed by the window server notifications of the window, so
// each one does only what its notification can have changed: SkyLight calls are cheap, but yabai makes many of them.
//
// BORDER_UPDATE_COLOR only redraws the edges of a shown border in its current color, without asking the window server
// about the window. A focus change needs nothing else, and it happens while the application of the window is busy
// becoming active: the window server can hold back its replies about the window until then, for up to half a second.
//
private let borderUpdateFrame = 1
private let borderUpdateOrder = 2
private let borderUpdateColor = 4
private let borderUpdateAll = 3

private func borderCurrentColor(_ border: Border, _ settings: BorderSettings) -> rgba_color
{
    border.focused ? settings.activeColor : settings.normalColor
}

//
// NOTE: Returns false when the window has no bounds anymore, so the border has to be hidden.
//
private func borderUpdateFrameLocked(_ border: Border, _ settings: BorderSettings) -> Bool
{
    guard let bounds = SLS.windowBounds(connection_global(), border.wid) else { return false }
    let frame = borderTargetFrame(border, bounds)
    let radius = borderTargetRadius(border)
    let color = borderCurrentColor(border, settings)
    let restyled = border.width != settings.width || radius != border.drawnRadius || color.p != border.color
    let previous = border.edges
    border.frame = frame
    border.width = settings.width
    border.drawnRadius = radius
    border.color = color.p
    border.edges = borderEdgeFrames(frame, border.width, radius)
    let created = border.ids[0] == 0
    if created {
        for i in 0..<4 { borderCreateEdge(border, i) }
        border.sid = nil
        border.sticky = false
        border.level = .min
        border.subLevel = .min
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
            list[i] = created || previous[i].size != border.edges[i].size
            anyReshaped = anyReshaped || list[i]
        }
    }
    if anyReshaped { SLSDisableUpdate(connection_global()) }
    withUnsafeBytes(of: reshaped) { raw in
        let list = raw.bindMemory(to: Bool.self)
        for i in 0..<4 {
            if list[i] && !created { borderReshapeEdge(border, i) }
            if list[i] || restyled { borderDrawEdge(border, i, color) }
            SLSMoveWindow(connection_global(), border.ids[i], &border.edges[i].origin)
        }
    }
    if anyReshaped { SLSReenableUpdate(connection_global()) }
    return true
}

private func borderUpdateOrderLocked(_ border: Border)
{
    let level = window_level(border.wid)
    let subLevel = window_sub_level(border.wid)
    for i in 0..<4 {
        if level != border.level { SLSSetWindowLevel(connection_global(), border.ids[i], level) }
        if subLevel != border.subLevel { SLSSetWindowSubLevel(connection_global(), border.ids[i], subLevel) }
        //
        // NOTE: A side edge of a window shorter than two corners is empty, so it stays hidden.
        //
        if border.edges[i].width > 0 && border.edges[i].height > 0 { SLSOrderWindow(connection_global(), border.ids[i], -1, border.wid.rawValue) }
        else { SLSOrderWindow(connection_global(), border.ids[i], 0, 0) }
    }
    border.level = level
    border.subLevel = subLevel
    //
    // NOTE: The edges are put on the space of the window after they are ordered, because ordering them in can
    // move them to the active space.
    //
    let sticky = window_is_sticky(border.wid)
    let sid = window_space(border.wid)
    if !sticky, let sid, window_space(WindowID(border.ids[0])) != sid { borderMoveToSpace(border, sid) }
    if let sid { border.sid = sid }
    borderSetSticky(border, sticky)
}

private func borderUpdateLocked(_ border: Border, _ what: Int, _ settings: BorderSettings)
{
    if !settings.enabled || !border.enabled || border.suspended { borderHide(border); return }
    let what = border.shown ? what : borderUpdateAll
    if what == borderUpdateColor {
        let color = borderCurrentColor(border, settings)
        for i in 0..<4 { borderDrawEdge(border, i, color) }
        border.color = color.p
        return
    }
    if what & borderUpdateOrder != 0 && !SLS.windowIsOrderedIn(connection_global(), border.wid) { borderHide(border); return }
    if what & borderUpdateFrame != 0 && !borderUpdateFrameLocked(border, settings) { borderHide(border); return }
    if what & borderUpdateOrder != 0 { borderUpdateOrderLocked(border) }
    border.shown = true
}

//
// NOTE: Gives the shown edges of from to the border to, which goes around the same frame, and the hidden edges of to
// to from. The edges stay ordered in and are only moved below the window of to, which shares the level and the space
// of the window of from, and redrawn when the color differs, all within one update of the screen.
//
private func borderHandOver(_ from: Border, _ to: Border, _ settings: BorderSettings)
{
    swap(&from.ids, &to.ids)
    swap(&from.contexts, &to.contexts)
    swap(&from.edges, &to.edges)
    swap(&from.frame, &to.frame)
    swap(&from.sid, &to.sid)
    swap(&from.drawnRadius, &to.drawnRadius)
    swap(&from.width, &to.width)
    swap(&from.color, &to.color)
    swap(&from.sticky, &to.sticky)
    swap(&from.level, &to.level)
    swap(&from.subLevel, &to.subLevel)
    to.shown = true
    from.shown = false
    SLSDisableUpdate(connection_global())
    borderUpdateLocked(to, borderUpdateFrame, settings)
    if to.shown {
        for i in 0..<4 where to.edges[i].width > 0 && to.edges[i].height > 0 { SLSOrderWindow(connection_global(), to.ids[i], -1, to.wid.rawValue) }
    }
    SLSReenableUpdate(connection_global())
}

private func borderShouldShow(_ target: Window) -> Bool
{
    if !target.is_eligible { return false }
    guard let app = target.application, !app.is_hidden else { return false }
    if target.isMinimized { return false }
    if target.isFullscreen { return false }
    if target.isManagedByRule { return true }
    return window_is_standard(target) && window_level_is_standard(target)
}

//
// NOTE: The number of windows that count for window_border_hide_single on a space: the tiled windows, where a tabbed
// container contributes the visible windows of its active tab, and the visible floating windows. Scratchpads do not count.
//
private func borderSpaceWindowCount(_ sid: SpaceID?) -> Int
{
    var count = 0
    if let sid {
        let owner = space_manager_find_view(space_manager_global(), sid)
        count = owner.layout == .tree ? owner.tree?.visibleWindowCount() ?? 0 : 0
    }
    for target in window_manager_global().window.values {
        if target.scratchpad != nil || !borderShouldShow(target) { continue }
        if window_manager_find_managed_window(window_manager_global(), target) != nil { continue }
        if window_space(target.id) != sid { continue }
        if SLS.windowIsOrderedIn(connection_global(), target.id) { count += 1 }
    }
    return count
}

/// Refreshes the border of a window; windowCount is the count of borderSpaceWindowCount for its space, nil when it
/// still has to be counted.
private func borderRefreshWithCount(_ target: Window?, _ sid: SpaceID?, _ windowCount: Int?)
{
    guard let target, !target.isDestroyed else { return }
    let wm = window_manager_global()
    let owner = window_manager_find_managed_window(wm, target)
    let border = owner?.borderArea(windowID: target.id) ?? (visible: true, window: Area.zero, border: Area.zero, radius: 0)
    let windowArea = border.window
    let borderArea = border.border
    let containerRadius = border.radius
    var enabled = wm.enable_window_border && borderShouldShow(target) && border.visible
    if enabled && wm.window_border_hide_single && owner != nil && target.scratchpad == nil {
        let count = windowCount ?? borderSpaceWindowCount(sid ?? window_space(target.id))
        enabled = count > 1
    }
    let focused = wm.focused_window_id == target.id
    borderLock.withLock { state in
        state.settings.enabled = wm.enable_window_border
        state.settings.width = wm.window_border_width
        state.settings.activeColor = wm.active_window_border_color
        state.settings.normalColor = wm.normal_window_border_color
        if state.borders[target.id] == nil && enabled {
            let border = Border(target.id)
            border.radius = borderWindowRadius(target.id)
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
        let recolored = border.color != color.p
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
        else if changed { borderUpdateLocked(border, borderUpdateAll, state.settings) }
        else if recolored { borderUpdateLocked(border, borderUpdateColor, state.settings) }
    }
}

func border_begin_batch() { borderLock.withLock { $0.batchDepth += 1 } }

func border_end_batch()
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
            if let shown { borderHandOver(shown, border, state.settings) }
            else { borderUpdateLocked(border, borderUpdateAll, state.settings) }
        }
        for wid in state.hide {
            if let border = state.borders[wid], !border.enabled { borderHide(border) }
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
func border_refresh(_ target: Window!) { borderRefreshWithCount(target, nil, nil) }

//
// NOTE: Without window_border_hide_single a change on a space only affects the borders of its tiled windows and of
// the windows that had a border there (e.g. a window that just stopped being tiled), so only those are refreshed,
// without asking the window server for the space of every window.
//
func border_refresh_space(_ sid: SpaceID?)
{
    guard let sid else { return }
    border_begin_batch()
    defer { border_end_batch() }
    if window_manager_global().window_border_hide_single {
        let count = borderSpaceWindowCount(sid)
        for target in window_manager_global().window.values where window_space(target.id) == sid { borderRefreshWithCount(target, sid, count) }
        return
    }
    var windows: [WindowID] = []
    let owner = space_manager_find_view(space_manager_global(), sid)
    if owner.layout == .tree { windows = owner.windowIDs }
    let capacity = windows.count + window_manager_global().window.count
    borderLock.withLock { state in
        for border in state.borders.values where border.sid == sid {
            if !windows.contains(border.wid) && windows.count < capacity { windows.append(border.wid) }
        }
    }
    for wid in windows { borderRefreshWithCount(window_manager_find_window(window_manager_global(), wid), sid, 0) }
}

func border_refresh_window_space(_ target: Window!)
{
    guard let target, !target.isDestroyed else { return }
    let sid = window_space(target.id)
    if window_manager_global().window_border_hide_single, let sid { border_refresh_space(sid) }
    else { border_refresh(target) }
}

func border_refresh_all()
{
    var counts: [SpaceID: Int] = [:]
    for target in window_manager_global().window.values {
        let sid = window_space(target.id)
        var count: Int?
        if window_manager_global().window_border_hide_single, let sid {
            count = counts[sid]
            if count == nil {
                let spaceCount = borderSpaceWindowCount(sid)
                if counts.count < 64 { counts[sid] = spaceCount }
                count = spaceCount
            }
        }
        borderRefreshWithCount(target, sid, count)
    }
}

func border_remove(_ wid: WindowID)
{
    borderLock.withLock { state in
        if let border = state.borders.removeValue(forKey: wid) { borderRelease(border) }
    }
}

//
// NOTE: A window that is animated is drawn by a proxy window in its place while the real window already sits at its
// final frame, so its border is hidden for the duration of the animation and put back at the end.
//
func border_suspend(_ wid: WindowID, _ suspended: Bool)
{
    borderLock.withLock { state in
        if let border = state.borders[wid] {
            border.suspended = suspended
            borderUpdateLocked(border, borderUpdateAll, state.settings)
        }
    }
}

//
// NOTE: The handlers below run on the main thread, straight from the SkyLight notifications of the window.
//
func border_window_moved(_ wid: WindowID)
{
    borderLock.withLock { state in
        guard let border = state.borders[wid], border.shown, let bounds = SLS.windowBounds(connection_global(), wid) else { return }
        let frame = borderTargetFrame(border, bounds)
        if frame.size != border.frame.size { borderUpdateLocked(border, borderUpdateFrame, state.settings); return }
        border.frame = frame
        border.edges = borderEdgeFrames(frame, border.width, border.drawnRadius)
        for i in 0..<4 { SLSMoveWindow(connection_global(), border.ids[i], &border.edges[i].origin) }
    }
}

private func borderWindowUpdate(_ wid: WindowID, _ what: Int)
{
    borderLock.withLock { state in
        if let border = state.borders[wid], border.enabled { borderUpdateLocked(border, what, state.settings) }
    }
}

func border_window_resized(_ wid: WindowID) { borderWindowUpdate(wid, borderUpdateFrame) }
func border_window_ordered(_ wid: WindowID) { borderWindowUpdate(wid, borderUpdateOrder) }
func border_window_changed(_ wid: WindowID) { borderWindowUpdate(wid, borderUpdateAll) }
func border_window_hidden(_ wid: WindowID)
{
    borderLock.withLock { state in
        if let border = state.borders[wid] { borderHide(border) }
    }
}
