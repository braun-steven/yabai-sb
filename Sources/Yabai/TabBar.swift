import AppKit
import CoreText
import Synchronization
import CPrivate
import YabaiC

//
// NOTE: Tab bars that currently own a window. Only touched from the event loop thread.
// A bar is embedded in its owner (a stack leaf or a tabbed container), and the owner
// redraws it through the callback when colors or fonts change.
//
nonisolated(unsafe) private var tabBarList: [UnsafeMutablePointer<tab_bar>] = []

//
// NOTE: Snapshot of the visible tab layout, read by the mouse event tap to resolve clicks on a
// tab bar without touching the window tree from another thread.
//
private struct TabBarHit: Sendable
{
    let frame: CGRect
    let sid: UInt64
    let aboveWid: UInt32
    let entries: [UInt32]
}
private let tabBarHits = Mutex<[TabBarHit]>([])

@_cdecl("tab_bar_set_font")
func tab_bar_set_font(_ name: UnsafeMutablePointer<CChar>!) -> Bool
{
    guard let separator = strrchr(name, 58), separator != name else { return false }
    var size: Float = 0
    guard sscanfFloatC(separator + 1, &size) == 1, !(size <= 0) else { return false }
    let length = name.distance(to: separator)
    let font: CTFont?
    if length == 6 && strncmp(name, "system", length) == 0 {
        font = CTFontCreateUIFontForLanguage(.system, CGFloat(size), nil)
    } else {
        guard let family = CFStringCreateWithBytes(nil, UnsafeRawPointer(name).assumingMemoryBound(to: UInt8.self), length, CFStringBuiltInEncodings.UTF8.rawValue, false) else { return false }
        font = CTFontCreateWithName(family, CGFloat(size), nil)
    }
    guard let font else { return false }
    let wm = window_manager_global()!
    wm.pointee.tab_bar_font?.release()
    free(wm.pointee.tab_bar_font_name)
    wm.pointee.tab_bar_font = .passRetained(font)
    wm.pointee.tab_bar_font_name = strdup(name)
    return true
}

@_cdecl("tab_bar_parse_style")
func tab_bar_parse_style(_ name: UnsafeMutablePointer<CChar>!, _ style: UnsafeMutablePointer<tab_bar_style>!) -> Bool
{
    if strcmp(name, "glass") == 0 { style.pointee = TAB_BAR_STYLE_GLASS; return true }
    if strcmp(name, "i3") == 0 { style.pointee = TAB_BAR_STYLE_I3; return true }
    return false
}

@_cdecl("tab_bar_parse_backdrop")
func tab_bar_parse_backdrop(_ name: UnsafeMutablePointer<CChar>!, _ backdrop: UnsafeMutablePointer<tab_bar_backdrop>!) -> Bool
{
    if strcmp(name, "off") == 0 { backdrop.pointee = TAB_BAR_BACKDROP_OFF; return true }
    if strcmp(name, "glass") == 0 { backdrop.pointee = TAB_BAR_BACKDROP_GLASS; return true }
    if strcmp(name, "blur") == 0 { backdrop.pointee = TAB_BAR_BACKDROP_BLUR; return true }
    return false
}

@_cdecl("tab_bar_is_enabled")
func tab_bar_is_enabled() -> Bool
{
    let wm = window_manager_global()!
    return wm.pointee.enable_tab_bar && wm.pointee.tab_bar_height > 0
}

private func tabBarPublishHits()
{
    tabBarHits.withLock { hits in
        hits.removeAll(keepingCapacity: true)
        for bar in tabBarList where hits.count < 256 {
            if bar.pointee.hidden || bar.pointee.entry_count == 0 { continue }
            let entries = withUnsafeBytes(of: bar.pointee.entry_list) {
                Array($0.bindMemory(to: UInt32.self).prefix(Int(bar.pointee.entry_count)))
            }
            hits.append(TabBarHit(frame: bar.pointee.frame, sid: bar.pointee.sid, aboveWid: bar.pointee.above_wid, entries: entries))
        }
    }
}

//
// NOTE: The bar only sits right above the window it belongs to, so windows ordered in front of that
// window (menu bar extras, Control Center, notifications, floating windows) may cover it. A click goes
// to the bar only when the window that would receive it is one of ours or is ordered behind the bar.
//
private func tabBarIsCovered(_ point: CGPoint, _ aboveWid: UInt32) -> Bool
{
    var point = point
    var windowPoint = CGPoint.zero
    var wid: UInt32 = 0
    var cid: Int32 = 0
    SLSFindWindowAndOwner(connection_global(), 0, 1, 0, &point, &windowPoint, &wid, &cid)
    if wid == 0 || cid == connection_global() || wid == aboveWid { return false }
    guard let windows = CGWindowListCreateC(.optionOnScreenAboveWindow, aboveWid) else { return false }
    return CFArrayContainsValue(windows, CFRange(location: 0, length: CFArrayGetCount(windows)), UnsafeRawPointer(bitPattern: UInt(wid)))
}

@_cdecl("tab_bar_hit_test")
func tab_bar_hit_test(_ point: CGPoint, _ wid: UnsafeMutablePointer<UInt32>!) -> Bool
{
    let above: UInt32? = tabBarHits.withLock { hits in
        for hit in hits {
            if !hit.frame.contains(point) || !space_is_visible(hit.sid) { continue }
            let index = max(0, min(hit.entries.count - 1, Int((point.x - hit.frame.minX) * CGFloat(hit.entries.count) / hit.frame.width)))
            wid.pointee = hit.entries[index]
            return hit.aboveWid
        }
        return nil
    }
    return above.map { !tabBarIsCovered(point, $0) } ?? false
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

@_cdecl("tab_bar_copy_title")
func tabBarCopyTitle(_ wid: UInt32) -> Unmanaged<CFString>?
{
    guard let target = window_manager_find_window(window_manager_global(), wid) else { return nil }
    if let title = target.pointee.title?.takeUnretainedValue(), CFStringGetLength(title) > 0 { return .passRetained(title) }
    if let app = target.pointee.application, let name = app.pointee.name,
       let title = CFStringCreateWithCString(nil, name, CFStringBuiltInEncodings.UTF8.rawValue) { return .passRetained(title) }
    return nil
}

//
// NOTE: The application icon of a window, loaded once per application and owned by it.
//
@_cdecl("tab_bar_icon")
func tabBarIcon(_ wid: UInt32) -> Unmanaged<CGImage>?
{
    guard window_manager_global().pointee.tab_bar_icons,
          let target = window_manager_find_window(window_manager_global(), wid), let app = target.pointee.application else { return nil }
    if let icon = app.pointee.icon { return icon }
    autoreleasepool {
        if let image = NSRunningApplication(processIdentifier: app.pointee.pid)?.icon {
            var rect = CGRect(x: 0, y: 0, width: 64, height: 64)
            if let icon = image.cgImage(forProposedRect: &rect, context: nil, hints: nil) { app.pointee.icon = .passRetained(icon) }
        }
    }
    return app.pointee.icon
}

func tabBarStateColors(_ state: tab_bar_state) -> (rgba_color, rgba_color)
{
    let wm = window_manager_global()!.pointee
    switch state {
    case TAB_BAR_FOCUSED: return (wm.tab_bar_focused_color, wm.tab_bar_focused_text_color)
    case TAB_BAR_INACTIVE: return (wm.tab_bar_inactive_color, wm.tab_bar_inactive_text_color)
    default: return (wm.tab_bar_unfocused_color, wm.tab_bar_unfocused_text_color)
    }
}

func tabBarSeparatorColor(_ text: rgba_color) -> rgba_color
{
    var text = text
    text.a *= 0.25
    return text
}

private func tabBarDraw(_ bar: UnsafeMutablePointer<tab_bar>, _ entries: UnsafeMutablePointer<tab_bar_entry>, _ count: Int32)
{
    SLSDisableUpdate(connection_global())
    defer { SLSReenableUpdate(connection_global()) }
    guard let context = bar.pointee.context?.takeUnretainedValue() else { return }
    let bounds = CGRect(origin: .zero, size: bar.pointee.frame.size)
    context.clear(bounds)
    for i in 0..<Int(count) {
        let entry = entries[i]
        let (background, text) = tabBarStateColors(entry.state)
        let tab = tab_bar_slot(bounds, Int32(i), count)
        context.setFillColor(red: CGFloat(background.r), green: CGFloat(background.g), blue: CGFloat(background.b), alpha: CGFloat(background.a))
        context.fill(tab)
        if i > 0 {
            let separator = tabBarSeparatorColor(text)
            context.setFillColor(red: CGFloat(separator.r), green: CGFloat(separator.g), blue: CGFloat(separator.b), alpha: CGFloat(separator.a))
            context.fill(CGRect(x: tab.minX, y: 0, width: 1, height: bounds.height))
        }
        if entry.title != nil || entry.icon != nil {
            tab_bar_draw_title(context, window_manager_global().pointee.tab_bar_font?.takeUnretainedValue(), false, entry.title?.takeUnretainedValue(), entry.icon?.takeUnretainedValue(), tab, tabBarCGColor(text))
        }
    }
    context.flush()
}

private func tabBarUsesGlass() -> Bool { window_manager_global().pointee.tab_bar_style == TAB_BAR_STYLE_GLASS }

@_cdecl("tab_bar_card_padding")
func tab_bar_card_padding() -> Int32
{
    if !tabBarUsesGlass() || window_manager_global().pointee.tab_bar_backdrop == TAB_BAR_BACKDROP_OFF { return 0 }
    return window_manager_global().pointee.tab_bar_card_padding
}

private func tabBarExists(_ bar: UnsafeMutablePointer<tab_bar>) -> Bool { bar.pointee.id != 0 || bar.pointee.glass != nil }

private func tabBarCreate(_ bar: UnsafeMutablePointer<tab_bar>, _ frame: CGRect)
{
    bar.pointee.frame = frame
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
    SLSNewWindow(connection_global(), 2, 0, 0, shape, &bar.pointee.id)
    var tags: UInt64 = (1 << 1) | (1 << 9)
    SLSSetWindowTags(connection_global(), bar.pointee.id, &tags, 64)
    sls_window_disable_shadow(bar.pointee.id)
    SLSSetWindowResolution(connection_global(), bar.pointee.id, 2)
    SLSSetWindowOpacity(connection_global(), bar.pointee.id, false)
    if let context = SLWindowContextCreate(connection_global(), bar.pointee.id, nil) { bar.pointee.context = .passRetained(context) }
}

//
// NOTE: Ordering a bar in can still move it to the active space, so its space is checked after every order and
// fixed up when it no longer matches the space of the window it sits above.
//
private func tabBarKeepOnSpace(_ bar: UnsafeMutablePointer<tab_bar>)
{
    if bar.pointee.id == 0 || bar.pointee.sid == 0 || window_space(bar.pointee.id) == bar.pointee.sid { return }
    tab_bar_glass_move_to_space(bar.pointee.id, bar.pointee.sid)
}

//
// NOTE: Creates the bar window if needed, moves it to the frame and to the space of the window it
// sits above, draws the entries and orders it right above that window (right below it for a glass bar
// with a backdrop card, which then covers the whole card). Titles stay owned by the caller.
//
@_cdecl("tab_bar_render")
func tab_bar_render(_ bar: UnsafeMutablePointer<tab_bar>!, _ frame: CGRect, _ card: CGRect, _ aboveWid: UInt32, _ entries: UnsafeMutablePointer<tab_bar_entry>!, _ entryCount: Int32)
{
    bar.pointee.card = card
    let count = min(entryCount, Int32(TAB_BAR_MAX_ENTRY_COUNT))
    if !tabBarExists(bar) { tabBarCreate(bar, frame) }
    else if frame != bar.pointee.frame {
        if bar.pointee.id != 0 {
            var frame = frame
            var region: CFTypeRef?
            CGSNewRegionWithRect(&frame, &region)
            let shape = region!
            SLSDisableUpdate(connection_global())
            SLSSetWindowShape(connection_global(), bar.pointee.id, 0, 0, shape)
            SLSReenableUpdate(connection_global())
        }
        bar.pointee.frame = frame
    }
    let sid = window_space(aboveWid)
    if sid != 0 && sid != bar.pointee.sid {
        if bar.pointee.id != 0 { tab_bar_glass_move_to_space(bar.pointee.id, sid) }
        bar.pointee.sid = sid
    }
    bar.pointee.above_wid = aboveWid
    bar.pointee.hidden = false
    bar.pointee.entry_count = count
    withUnsafeMutableBytes(of: &bar.pointee.entry_list) { raw in
        let list = raw.bindMemory(to: UInt32.self)
        for i in 0..<Int(count) { list[i] = entries[i].focus_wid }
    }
    if bar.pointee.id != 0 {
        tabBarDraw(bar, entries, count)
        SLSSetWindowLevel(connection_global(), bar.pointee.id, window_level(aboveWid))
        SLSSetWindowSubLevel(connection_global(), bar.pointee.id, window_sub_level(aboveWid))
        SLSOrderWindow(connection_global(), bar.pointee.id, 1, aboveWid)
        tabBarKeepOnSpace(bar)
    } else { tab_bar_glass_render(bar, aboveWid, entries, count) }
    tabBarPublishHits()
}

@_cdecl("tab_bar_hide")
func tab_bar_hide(_ bar: UnsafeMutablePointer<tab_bar>!)
{
    if !tabBarExists(bar) || bar.pointee.hidden { return }
    if bar.pointee.id != 0 { SLSOrderWindow(connection_global(), bar.pointee.id, 0, 0) }
    else { tab_bar_glass_hide(bar) }
    bar.pointee.hidden = true
    tabBarPublishHits()
}

@_cdecl("tab_bar_release")
func tab_bar_release(_ bar: UnsafeMutablePointer<tab_bar>!)
{
    if !tabBarExists(bar) { return }
    if let i = tabBarList.firstIndex(of: bar) { tabBarList.remove(at: i) }
    if bar.pointee.id != 0 {
        SLSOrderWindow(connection_global(), bar.pointee.id, 0, 0)
        bar.pointee.context?.release()
        SLSReleaseWindow(connection_global(), bar.pointee.id)
    } else { tab_bar_glass_release(bar) }
    let owner = bar.pointee.owner
    let redraw = bar.pointee.redraw
    bar.pointee = tab_bar()
    bar.pointee.owner = owner
    bar.pointee.redraw = redraw
    tabBarPublishHits()
}

//
// NOTE: Window id of the backdrop card of a visible bar, or 0 when it has none (yet). The panel is created on the
// main queue, so the id only becomes known after the first update of the bar reaches it.
//
@_cdecl("tab_bar_card_id")
func tab_bar_card_id(_ bar: UnsafeMutablePointer<tab_bar>!) -> UInt32
{
    if bar.pointee.hidden || bar.pointee.glass == nil { return 0 }
    if !tabBarUsesGlass() || window_manager_global().pointee.tab_bar_backdrop == TAB_BAR_BACKDROP_OFF { return 0 }
    return tab_bar_glass_panel_id(bar)
}

@_cdecl("tab_bar_order")
func tab_bar_order(_ wid: UInt32)
{
    for bar in tabBarList {
        if bar.pointee.hidden || bar.pointee.above_wid != wid { continue }
        if bar.pointee.id != 0 {
            SLSOrderWindow(connection_global(), bar.pointee.id, 1, wid)
            tabBarKeepOnSpace(bar)
        } else { tab_bar_glass_order(bar, wid) }
    }
}

@_cdecl("tab_bar_redraw_all")
func tab_bar_redraw_all()
{
    for bar in tabBarList { bar.pointee.redraw?(bar.pointee.owner) }
}

@_cdecl("tab_bar_refresh_for_window")
func tab_bar_refresh_for_window(_ wid: UInt32)
{
    if wid == 0 { return }
    var wid = wid
    guard let raw = table_find(&window_manager_global().pointee.managed_window, &wid) else { return }
    let owner = raw.assumingMemoryBound(to: view.self)
    if owner.pointee.layout != VIEW_TREE { return }
    tree_refresh_for_window(wid)
}

//
// NOTE: Called after a tab bar config change that affects the layout. Drops every bar so that the next layout pass
// recreates them with the new settings, then re-lays out all views to apply the new window area.
//
@_cdecl("tab_bar_refresh_all")
func tab_bar_refresh_all()
{
    for owner in tableValues(space_manager_global().pointee.view, as: view.self) where owner.pointee.layout == VIEW_TREE {
        if let root = owner.pointee.tree { tree_release_bars(root) }
        view_update_and_flush(owner)
    }
    tabBarPublishHits()
}
