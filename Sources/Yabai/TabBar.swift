import AppKit
import CoreText
import Synchronization
import CPrivate
import YabaiCore

/// The classic bar window or native glass panel, and the tabs it shows.
final class TabBar
{
    var id: WindowID?
    var context: CGContext?
    var frame = CGRect.zero
    var card = CGRect.zero
    var sid: SpaceID?
    var above_wid: WindowID?
    var hidden = false
    var entry_count = 0
    var entry_list: [WindowID?] = []
    var glass: TabBarGlass?
    var owner: UnsafeMutableRawPointer?
    var redraw: (@convention(c) (UnsafeMutableRawPointer?) -> Void)?

    /// The empty bar of tab_bar_release, which keeps its owner and callback.
    func reset()
    {
        id = nil
        context = nil
        frame = .zero
        card = .zero
        sid = nil
        above_wid = nil
        hidden = false
        entry_count = 0
        entry_list = []
        glass = nil
    }
}

extension TabBar: Equatable
{
    static func == (a: TabBar, b: TabBar) -> Bool { a === b }
}

/// How tab bars are drawn (`config tab_bar_style`).
enum TabBarStyle: String, CaseIterable, Sendable
{
    case glass
    case i3
}

/// The card behind a glass tab bar (`config tab_bar_backdrop`).
enum TabBarBackdrop: String, CaseIterable, Sendable
{
    case off
    case glass
    case blur
}

/// The colors of glass tab bars (`config tab_bar_appearance`).
enum TabBarAppearance: String, CaseIterable, Sendable
{
    case dark
    case system
}

/// The state of a tab: the focused window's tab, the active tab of an unfocused container, or any other tab.
enum TabBarState: Sendable
{
    case unfocused
    case inactive
    case focused
}

/// The font of the tab bars until `config tab_bar_font` sets one.
let tabBarDefaultFont = "system:12"

/// The most tabs a tab bar shows.
let tabBarMaxEntryCount = 64

/// `tab_bar_slot`: the tab at the index among count tabs of the area, with the C rounding (float widths, int offsets).
func tab_bar_slot(_ area: CGRect, _ index: Int, _ count: Int) -> CGRect
{
    let width = Float(area.size.width / CGFloat(count))
    let x0 = Float(area.origin.x + CGFloat(Int(Float(index) * width)))
    let x1 = index == count - 1 ? Float(area.origin.x + area.size.width) : Float(area.origin.x + CGFloat(Int(Float(index + 1) * width)))
    return CGRect(x: CGFloat(x0), y: area.origin.y, width: CGFloat(x1 - x0), height: area.size.height)
}

/// `struct tab_bar_entry` (tab_bar.h)
struct TabBarEntry
{
    var focus_wid: WindowID?
    var title: CFString?
    var icon: CGImage?
    var state: TabBarState
}

//
// NOTE: Tab bars that currently own a window. Only touched from the event loop thread.
// A bar is embedded in its owner (a stack leaf or a tabbed container), and the owner
// redraws it through the callback when colors or fonts change.
//
nonisolated(unsafe) private var tabBarList: [TabBar] = []

//
// NOTE: Snapshot of the visible tab layout, read by the mouse event tap to resolve clicks on a
// tab bar without touching the window tree from another thread.
//
private struct TabBarHit: Sendable
{
    let frame: CGRect
    let sid: SpaceID
    let aboveWid: WindowID
    let entries: [WindowID?]
    let glass: TabBarGlass?
}
private let tabBarHits = Mutex<[TabBarHit]>([])

//
// NOTE: The font is "<family>:<size>", split at the last ':'. The size is read with sscanf "%f", which skips leading
// whitespace and ignores trailing text. The family "system" is the system UI font.
//

func tab_bar_set_font(_ name: String) -> Bool
{
    let utf8 = name.utf8
    guard let separator = utf8.lastIndex(of: UInt8(ascii: ":")), separator != utf8.startIndex else { return false }
    var size: Float = 0
    let sizeText = Token(utf8[utf8.index(after: separator)...])
    guard withUnsafeMutablePointer(to: &size, { sizeText.scan("%f", $0) }) == 1, !(size <= 0) else { return false }
    let family = String(decoding: utf8[..<separator], as: UTF8.self)
    let font: CTFont? = string_equals(family, "system")
        ? CTFontCreateUIFontForLanguage(.system, CGFloat(size), nil)
        : CTFontCreateWithName(family as CFString, CGFloat(size), nil)
    guard let font else { return false }
    let wm = WindowManager.shared
    wm.tabBarFont = font
    wm.tabBarFontName = name
    return true
}

func tab_bar_is_enabled() -> Bool
{
    let wm = WindowManager.shared
    return wm.tabBarEnabled && wm.tabBarHeight > 0
}

private func tabBarPublishHits()
{
    tabBarHits.withLock { hits in
        hits.removeAll(keepingCapacity: true)
        for bar in tabBarList where hits.count < 256 {
            if bar.hidden || bar.entry_count == 0 { continue }
            // NOTE: A bar that shows entries has been rendered above a window on a space, so both are set.
            guard let sid = bar.sid, let aboveWid = bar.above_wid else { continue }
            let entries = Array(bar.entry_list.prefix(bar.entry_count))
            hits.append(TabBarHit(frame: bar.frame, sid: sid, aboveWid: aboveWid, entries: entries, glass: bar.glass))
        }
    }
}

//
// NOTE: The bar only sits right above the window it belongs to, so windows ordered in front of that
// window (menu bar extras, Control Center, notifications, floating windows) may cover it. A click goes
// to the bar only when the window that would receive it is one of ours or is ordered behind the bar.
//
private func tabBarIsCovered(_ point: CGPoint, _ aboveWid: WindowID) -> Bool
{
    var point = point
    var windowPoint = CGPoint.zero
    var wid: UInt32 = 0
    var cid: Int32 = 0
    SLSFindWindowAndOwner(connection_global(), 0, 1, 0, &point, &windowPoint, &wid, &cid)
    if wid == 0 || cid == connection_global() || wid == aboveWid.rawValue { return false }
    guard let windows = CGWindowListCreateC(.optionOnScreenAboveWindow, aboveWid.rawValue) else { return false }
    return CFArrayContainsValue(windows, CFRange(location: 0, length: CFArrayGetCount(windows)), UnsafeRawPointer(bitPattern: UInt(wid)))
}

func tab_bar_hit_test(_ point: CGPoint, _ wid: UnsafeMutablePointer<WindowID?>!) -> Bool
{
    let above: WindowID? = tabBarHits.withLock { hits in
        for hit in hits {
            if !hit.frame.contains(point) || !hit.sid.isVisible { continue }
            guard let index = tabBarHitIndex(point, frame: hit.frame, count: hit.entries.count, glass: hit.glass != nil) else { continue }
            wid.pointee = hit.entries[index]
            return hit.aboveWid
        }
        return nil
    }
    return above.map { !tabBarIsCovered(point, $0) } ?? false
}

/// Match the drawn slots, including the rounded track's outer hit padding.
func tabBarHitIndex(_ point: CGPoint, frame: CGRect, count: Int, glass: Bool) -> Int?
{
    guard count > 0, frame.width > 0, frame.contains(point) else { return nil }
    let slots = glass ? tabBarGlassInnerRect(frame) : frame
    for index in 0..<count - 1 {
        if point.x < tab_bar_slot(slots, index, count).maxX { return index }
    }
    return count - 1
}

// NOTE: The event tap owns pointer state. It only sends changes to AppKit; it never reads the window tree.
private struct TabBarPointer: Sendable
{
    var glass: TabBarGlass?
    var windowID: WindowID?
    var pressed = false
}
private let tabBarPointer = Mutex(TabBarPointer())

func tab_bar_pointer_update(_ point: CGPoint, pressed: Bool)
{
    let hit = tabBarHits.withLock { hits in
        hits.first { $0.glass != nil && $0.frame.contains(point) && $0.sid.isVisible }
    }
    var glass: TabBarGlass?
    var windowID: WindowID?
    if let hit, !tabBarIsCovered(point, hit.aboveWid),
       let index = tabBarHitIndex(point, frame: hit.frame, count: hit.entries.count, glass: true) {
        glass = hit.glass
        windowID = hit.entries[index]
    }
    let change = tabBarPointer.withLock { state -> (Bool, TabBarGlass?) in
        guard state.glass !== glass || state.windowID != windowID || state.pressed != pressed else { return (false, nil) }
        let previous = state.glass
        state = TabBarPointer(glass: glass, windowID: windowID, pressed: pressed)
        return (true, previous)
    }
    guard change.0 else { return }
    if change.1 !== glass { change.1?.pointer(windowID: nil, pressed: false) }
    glass?.pointer(windowID: windowID, pressed: pressed)
}

func tabBarCGColor(_ color: rgba_color) -> CGColor
{
    CGColor(srgbRed: CGFloat(color.r), green: CGFloat(color.g), blue: CGFloat(color.b), alpha: CGFloat(color.a))
}

private func tabBarCreateLine(_ text: CFString, _ attributes: CFDictionary) -> CTLine
{
    CTLineCreateWithAttributedString(CFAttributedStringCreate(nil, text, attributes)!)
}

//
// NOTE: A title that is wider than max_width ends in an ellipsis.
//
func tabBarCreateFittedLine(_ title: CFString, _ attributes: CFDictionary, _ maxWidth: Double) -> CTLine
{
    let line = tabBarCreateLine(title, attributes)
    if CTLineGetTypographicBounds(line, nil, nil, nil) <= maxWidth { return line }
    let token = tabBarCreateLine("…" as CFString, attributes)
    return CTLineCreateTruncatedLine(line, maxWidth, .end, token) ?? line
}

//
// NOTE: Draws the application icon (if any) left of the title and centers both in the tab.
// The title is truncated first; the icon is dropped only when the tab is too narrow for it.
//
func tab_bar_draw_title(_ context: CGContext, _ font: CTFont?, _ glass: Bool, _ title: CFString?, _ icon: CGImage?, _ rect: CGRect, _ color: CGColor)
{
    let maxWidth = rect.width - 16
    if maxWidth <= 0 { return }
    let iconSpacing: CGFloat = glass ? 6 : 5
    let iconSize = CGFloat(Int(glass ? min(16, rect.height - 4) : rect.height * CGFloat(Float(0.7))))
    let icon = iconSize <= 0 || iconSize > maxWidth ? nil : icon
    let textMaxWidth = icon != nil ? maxWidth - iconSize - iconSpacing : maxWidth
    let title = font == nil || textMaxWidth <= 0 ? nil : title
    var line: CTLine?
    var ascent: CGFloat = 0
    var descent: CGFloat = 0
    var textWidth = 0.0
    if let title, let font {
        let attributes = [kCTFontAttributeName: font, kCTForegroundColorAttributeName: color] as CFDictionary
        line = tabBarCreateFittedLine(title, attributes, textMaxWidth)
        textWidth = CTLineGetTypographicBounds(line!, &ascent, &descent, nil)
    }
    var contentWidth = textWidth
    if icon != nil { contentWidth += iconSize + (line != nil ? iconSpacing : 0) }
    var x = CGFloat(Int(rect.minX + (rect.width - contentWidth) * 0.5))
    if let icon {
        let y = CGFloat(Int(rect.minY + (rect.height - iconSize) * 0.5))
        context.interpolationQuality = .high
        context.draw(icon, in: CGRect(x: x, y: y, width: iconSize, height: iconSize))
        x += iconSize + iconSpacing
    }
    if let line, let font {
        //
        // NOTE: The glass style centers the cap height like AppKit controls do, which puts the
        // title on the optical center of the tab instead of the center of ascent and descent.
        //
        let y = glass ? rect.minY + (rect.height - CTFontGetCapHeight(font)) * 0.5
                      : rect.minY + (rect.height - (ascent + descent)) * 0.5 + descent
        context.textMatrix = .identity
        context.textPosition = CGPoint(x: Int(x), y: Int(y))
        CTLineDraw(line, context)
    }
}

func tab_bar_copy_title(_ wid: WindowID?) -> CFString?
{
    guard let wid, let target = WindowManager.shared.window(for: wid) else { return nil }
    if let title = target.title, CFStringGetLength(title) > 0 { return title }
    if let app = target.application { return app.name as CFString }
    return nil
}

//
// NOTE: The application icon of a window, loaded once per application and owned by it.
//
func tab_bar_icon(_ wid: WindowID?) -> CGImage?
{
    guard WindowManager.shared.tabBarIcons, let wid,
          let target = WindowManager.shared.window(for: wid), let app = target.application else { return nil }
    if let icon = app.icon { return icon }
    autoreleasepool {
        if let image = NSRunningApplication(processIdentifier: app.pid)?.icon {
            var rect = CGRect(x: 0, y: 0, width: 64, height: 64)
            if let icon = image.cgImage(forProposedRect: &rect, context: nil, hints: nil) { app.icon = icon }
        }
    }
    return app.icon
}

func tabBarStateColors(_ state: TabBarState) -> (rgba_color, rgba_color)
{
    let wm = WindowManager.shared
    switch state {
    case .focused:   return (wm.tabBarFocusedColor, wm.tabBarFocusedTextColor)
    case .inactive:  return (wm.tabBarInactiveColor, wm.tabBarInactiveTextColor)
    case .unfocused: return (wm.tabBarUnfocusedColor, wm.tabBarUnfocusedTextColor)
    }
}

func tabBarSeparatorColor(_ text: rgba_color) -> rgba_color
{
    var text = text
    text.a *= 0.25
    return text
}

private func tabBarDraw(_ bar: TabBar, _ entries: UnsafeMutablePointer<TabBarEntry>, _ count: Int)
{
    SLSDisableUpdate(connection_global())
    defer { SLSReenableUpdate(connection_global()) }
    guard let context = bar.context else { return }
    let bounds = CGRect(origin: .zero, size: bar.frame.size)
    context.clear(bounds)
    for i in 0..<count {
        let entry = entries[i]
        let (background, text) = tabBarStateColors(entry.state)
        let tab = tab_bar_slot(bounds, i, count)
        context.setFillColor(red: CGFloat(background.r), green: CGFloat(background.g), blue: CGFloat(background.b), alpha: CGFloat(background.a))
        context.fill(tab)
        if i > 0 {
            let separator = tabBarSeparatorColor(text)
            context.setFillColor(red: CGFloat(separator.r), green: CGFloat(separator.g), blue: CGFloat(separator.b), alpha: CGFloat(separator.a))
            context.fill(CGRect(x: tab.minX, y: 0, width: 1, height: bounds.height))
        }
        if entry.title != nil || entry.icon != nil {
            tab_bar_draw_title(context, WindowManager.shared.tabBarFont, false, entry.title, entry.icon, tab, tabBarCGColor(text))
        }
    }
    context.flush()
}

private func tabBarUsesGlass() -> Bool { WindowManager.shared.tabBarStyle == .glass }

func tab_bar_card_padding() -> Int
{
    if !tabBarUsesGlass() || WindowManager.shared.tabBarBackdrop == .off { return 0 }
    return WindowManager.shared.tabBarCardPadding
}

private func tabBarExists(_ bar: TabBar) -> Bool { bar.id != nil || bar.glass != nil }

private func tabBarCreate(_ bar: TabBar, _ frame: CGRect)
{
    bar.frame = frame
    tabBarList.append(bar)
    if tabBarUsesGlass() { return }
    //
    // NOTE: Created with SLSNewWindow instead of SLSNewWindowWithOpaqueShapeAndContext, because a window of the latter
    // is moved to the active space each time it is ordered in again, so a bar that was hidden and shown again would
    // land on whatever space is visible instead of the space of its window.
    //
    var frame = frame
    var region: CFTypeRef?
    CGSNewRegionWithRect(&frame, &region)
    let shape = region!
    var barID: UInt32 = 0
    SLSNewWindow(connection_global(), 2, 0, 0, shape, &barID)
    bar.id = WindowID(nonzero: barID)
    guard let id = bar.id else { return }
    var tags: UInt64 = (1 << 1) | (1 << 9)
    SLSSetWindowTags(connection_global(), id.rawValue, &tags, 64)
    sls_window_disable_shadow(id.rawValue)
    SLSSetWindowResolution(connection_global(), id.rawValue, 2)
    SLSSetWindowOpacity(connection_global(), id.rawValue, false)
    bar.context = SLWindowContextCreate(connection_global(), id.rawValue, nil)
}

//
// NOTE: Ordering a bar in can still move it to the active space, so its space is checked after every order and
// fixed up when it no longer matches the space of the window it sits above.
//
private func tabBarKeepOnSpace(_ bar: TabBar)
{
    guard let id = bar.id, let sid = bar.sid, id.space != sid else { return }
    tab_bar_glass_move_to_space(id, sid)
}

//
// NOTE: Creates the bar window if needed, moves it to the frame and to the space of the window it
// sits above, draws the entries and orders it right above that window (right below it for a glass bar
// with a backdrop card, which then covers the whole card). Titles stay owned by the caller.
//
func tab_bar_render(_ bar: TabBar, _ frame: CGRect, _ card: CGRect, _ aboveWid: WindowID?, _ entries: UnsafeMutablePointer<TabBarEntry>, _ entryCount: Int)
{
    bar.card = card
    // NOTE: A bar without a window to sit above has nothing to be ordered against; it is hidden.
    guard let aboveWid else { tab_bar_hide(bar); return }
    let count = min(entryCount, tabBarMaxEntryCount)
    if !tabBarExists(bar) { tabBarCreate(bar, frame) }
    else if frame != bar.frame {
        if let id = bar.id {
            var frame = frame
            var region: CFTypeRef?
            CGSNewRegionWithRect(&frame, &region)
            let shape = region!
            SLSDisableUpdate(connection_global())
            SLSSetWindowShape(connection_global(), id.rawValue, 0, 0, shape)
            SLSReenableUpdate(connection_global())
        }
        bar.frame = frame
    }
    if let sid = aboveWid.space, sid != bar.sid {
        if let id = bar.id { tab_bar_glass_move_to_space(id, sid) }
        bar.sid = sid
    }
    bar.above_wid = aboveWid
    bar.hidden = false
    bar.entry_count = count
    bar.entry_list = (0..<count).map { entries[$0].focus_wid }
    if let id = bar.id {
        tabBarDraw(bar, entries, count)
        SLSSetWindowLevel(connection_global(), id.rawValue, aboveWid.level)
        SLSSetWindowSubLevel(connection_global(), id.rawValue, aboveWid.subLevel)
        SLSOrderWindow(connection_global(), id.rawValue, 1, aboveWid.rawValue)
        tabBarKeepOnSpace(bar)
    } else { tab_bar_glass_render(bar, aboveWid, entries, count) }
    tabBarPublishHits()
}

func tab_bar_hide(_ bar: TabBar)
{
    if !tabBarExists(bar) || bar.hidden { return }
    if let id = bar.id { SLSOrderWindow(connection_global(), id.rawValue, 0, 0) }
    else { tab_bar_glass_hide(bar) }
    bar.hidden = true
    tabBarPublishHits()
}

func tab_bar_release(_ bar: TabBar)
{
    if !tabBarExists(bar) { return }
    if let i = tabBarList.firstIndex(of: bar) { tabBarList.remove(at: i) }
    if let id = bar.id {
        SLSOrderWindow(connection_global(), id.rawValue, 0, 0)
        bar.context = nil
        SLSReleaseWindow(connection_global(), id.rawValue)
    } else { tab_bar_glass_release(bar) }
    bar.reset()
    tabBarPublishHits()
}

//
// NOTE: Window id of the backdrop card of a visible bar, or nil when it has none (yet). The panel is created on the
// main queue, so the id only becomes known after the first update of the bar reaches it.
//
func tab_bar_card_id(_ bar: TabBar) -> WindowID?
{
    if bar.hidden || bar.glass == nil { return nil }
    if !tabBarUsesGlass() || WindowManager.shared.tabBarBackdrop == .off { return nil }
    return tab_bar_glass_panel_id(bar)
}

func tab_bar_order(_ wid: WindowID)
{
    for bar in tabBarOuterFirst(tabBarList.filter { !$0.hidden && $0.above_wid == wid }) {
        if let id = bar.id {
            SLSOrderWindow(connection_global(), id.rawValue, 1, wid.rawValue)
            tabBarKeepOnSpace(bar)
        } else { tab_bar_glass_order(bar, wid) }
    }
}

// NOTE: Ordering each card below the same window puts the last card in front. Creation order changes when
// layouts or styles are rebuilt, so nested cards must explicitly be ordered from the outermost inward.
func tabBarOuterFirst(_ bars: [TabBar]) -> [TabBar]
{
    bars.sorted { $0.card.width * $0.card.height > $1.card.width * $1.card.height }
}

func tab_bar_redraw_all()
{
    for bar in tabBarOuterFirst(tabBarList) { bar.redraw?(bar.owner) }
}

func tab_bar_refresh_for_window(_ wid: WindowID?)
{
    guard let wid, let owner = WindowManager.shared.managedWindows[wid] else { return }
    if owner.layout != .tree { return }
    View.refreshBars(forWindowID: wid)
}

//
// NOTE: Called after a tab bar config change that affects the layout. Drops every bar so that the next layout pass
// recreates them with the new settings, then re-lays out all views to apply the new window area.
//
func tab_bar_refresh_all()
{
    for owner in space_manager_global().view.values.sorted(by: { $0.sid < $1.sid }) where owner.layout == .tree {
        owner.tree?.releaseBars()
        owner.updateAndFlush()
    }
    tabBarPublishHits()
}
