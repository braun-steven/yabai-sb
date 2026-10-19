import AppKit
import CoreText
import Synchronization
import CPrivate
import YabaiCore

/// The classic bar window or native glass panel, and the tabs it shows.
final class TabBar
{
    /// The font of the tab bars until `config tab_bar_font` sets one.
    static let defaultFont = "system:12"

    /// The most tabs a tab bar shows.
    static let maxEntryCount = 64

    var id: WindowID?
    var context: CGContext?
    var frame = CGRect.zero
    var card = CGRect.zero
    var sid: SpaceID?
    var aboveWindowID: WindowID?
    var hidden = false
    var entryCount = 0
    var entryWindowIDs: [WindowID?] = []
    var glass: TabBarGlass?
    // NOTE: The container that embeds the bar. It redraws the bar when colors or fonts change.
    weak var owner: Con?

    /// The empty bar of `destroy()`, which keeps its owner.
    func reset()
    {
        id = nil
        context = nil
        frame = .zero
        card = .zero
        sid = nil
        aboveWindowID = nil
        hidden = false
        entryCount = 0
        entryWindowIDs = []
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

extension TabBarState
{
    /// The background and text colors of a tab in this state.
    var colors: (background: RGBAColor, text: RGBAColor)
    {
        let wm = WindowManager.shared
        switch self {
        case .focused:   return (wm.tabBarFocusedColor, wm.tabBarFocusedTextColor)
        case .inactive:  return (wm.tabBarInactiveColor, wm.tabBarInactiveTextColor)
        case .unfocused: return (wm.tabBarUnfocusedColor, wm.tabBarUnfocusedTextColor)
        }
    }
}

extension RGBAColor
{
    var cgColor: CGColor
    {
        CGColor(srgbRed: CGFloat(r), green: CGFloat(g), blue: CGFloat(b), alpha: CGFloat(a))
    }
}

struct TabBarEntry
{
    var focusWindowID: WindowID?
    var title: CFString?
    var icon: CGImage?
    var state: TabBarState
}

//
// NOTE: Tab bars that currently own a window. Only touched from the event loop thread.
// A bar is embedded in its owner (a stack leaf or a tabbed container), and the owner
// redraws it when colors or fonts change.
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

extension TabBar
{
//
// NOTE: The font is "<family>:<size>", split at the last ':'. The size is read with sscanf "%f", which skips leading
// whitespace and ignores trailing text. The family "system" is the system UI font.
//

    /// The tab at the index among count tabs of the area, rounded with float widths and integer offsets.
    static func slot(in area: CGRect, index: Int, count: Int) -> CGRect
    {
        let width = Float(area.size.width / CGFloat(count))
        let x0 = Float(area.origin.x + CGFloat(Int(Float(index) * width)))
        let x1 = index == count - 1 ? Float(area.origin.x + area.size.width) : Float(area.origin.x + CGFloat(Int(Float(index + 1) * width)))
        return CGRect(x: CGFloat(x0), y: area.origin.y, width: CGFloat(x1 - x0), height: area.size.height)
    }

    static func setFont(_ name: String) -> Bool
    {
        let utf8 = name.utf8
        guard let separator = utf8.lastIndex(of: UInt8(ascii: ":")), separator != utf8.startIndex else { return false }
        var size: Float = 0
        let sizeText = Token(utf8[utf8.index(after: separator)...])
        guard withUnsafeMutablePointer(to: &size, { sizeText.scan("%f", $0) }) == 1, !(size <= 0) else { return false }
        let family = String(decoding: utf8[..<separator], as: UTF8.self)
        let font: CTFont? = family.bytesEqual("system")
            ? CTFontCreateUIFontForLanguage(.system, CGFloat(size), nil)
            : CTFontCreateWithName(family as CFString, CGFloat(size), nil)
        guard let font else { return false }
        let wm = WindowManager.shared
        wm.tabBarFont = font
        wm.tabBarFontName = name
        return true
    }

    static var isEnabled: Bool
    {
        let wm = WindowManager.shared
        return wm.tabBarEnabled && wm.tabBarHeight > 0
    }

    private static func publishHits()
    {
        tabBarHits.withLock { hits in
            hits.removeAll(keepingCapacity: true)
            for bar in tabBarList where hits.count < 256 {
                if bar.hidden || bar.entryCount == 0 { continue }
                // NOTE: A bar that shows entries has been rendered above a window on a space, so both are set.
                guard let sid = bar.sid, let aboveWid = bar.aboveWindowID else { continue }
                let entries = Array(bar.entryWindowIDs.prefix(bar.entryCount))
                hits.append(TabBarHit(frame: bar.frame, sid: sid, aboveWid: aboveWid, entries: entries, glass: bar.glass))
            }
        }
    }

    //
    // NOTE: The bar only sits right above the window it belongs to, so windows ordered in front of that
    // window (menu bar extras, Control Center, notifications, floating windows) may cover it. A click goes
    // to the bar only when the window that would receive it is one of ours or is ordered behind the bar.
    //
    private static func isCovered(_ point: CGPoint, above aboveWid: WindowID) -> Bool
    {
        var point = point
        var windowPoint = CGPoint.zero
        var wid: UInt32 = 0
        var cid: Int32 = 0
        SLSFindWindowAndOwner(SLS.connection, 0, 1, 0, &point, &windowPoint, &wid, &cid)
        if wid == 0 || cid == SLS.connection || wid == aboveWid.rawValue { return false }
        guard let windows = CGWindowListCreateC(.optionOnScreenAboveWindow, aboveWid.rawValue) else { return false }
        return CFArrayContainsValue(windows, CFRange(location: 0, length: CFArrayGetCount(windows)), UnsafeRawPointer(bitPattern: UInt(wid)))
    }

    static func hitTest(_ point: CGPoint, window: inout WindowID?) -> Bool
    {
        let above: WindowID? = tabBarHits.withLock { hits in
            for hit in hits {
                if !hit.frame.contains(point) || !hit.sid.isVisible { continue }
                guard let index = hitIndex(point, frame: hit.frame, count: hit.entries.count, glass: hit.glass != nil) else { continue }
                window = hit.entries[index]
                return hit.aboveWid
            }
            return nil
        }
        return above.map { !isCovered(point, above: $0) } ?? false
    }

    /// Match the drawn slots, including the rounded track's outer hit padding.
    static func hitIndex(_ point: CGPoint, frame: CGRect, count: Int, glass: Bool) -> Int?
    {
        guard count > 0, frame.width > 0, frame.contains(point) else { return nil }
        let slots = glass ? TabBarGlass.innerRect(frame) : frame
        for index in 0..<count - 1 {
            if point.x < slot(in: slots, index: index, count: count).maxX { return index }
        }
        return count - 1
    }

}

// NOTE: The event tap owns pointer state. It only sends changes to AppKit; it never reads the window tree.
private struct TabBarPointer: Sendable
{
    var glass: TabBarGlass?
    var windowID: WindowID?
    var pressed = false
}
private let tabBarPointer = Mutex(TabBarPointer())

extension TabBar
{
    static func updatePointer(_ point: CGPoint, pressed: Bool)
    {
        let hit = tabBarHits.withLock { hits in
            hits.first { $0.glass != nil && $0.frame.contains(point) && $0.sid.isVisible }
        }
        var glass: TabBarGlass?
        var windowID: WindowID?
        if let hit, !isCovered(point, above: hit.aboveWid),
           let index = hitIndex(point, frame: hit.frame, count: hit.entries.count, glass: true) {
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

    private static func line(_ text: CFString, _ attributes: CFDictionary) -> CTLine
    {
        CTLineCreateWithAttributedString(CFAttributedStringCreate(nil, text, attributes)!)
    }

    //
    // NOTE: A title that is wider than maxWidth ends in an ellipsis.
    //
    static func fittedLine(_ title: CFString, attributes: CFDictionary, maxWidth: Double) -> CTLine
    {
        let full = line(title, attributes)
        if CTLineGetTypographicBounds(full, nil, nil, nil) <= maxWidth { return full }
        let token = line("…" as CFString, attributes)
        return CTLineCreateTruncatedLine(full, maxWidth, .end, token) ?? full
    }

    //
    // NOTE: Draws the application icon (if any) left of the title and centers both in the tab.
    // The title is truncated first; the icon is dropped only when the tab is too narrow for it.
    //
    static func drawTitle(in context: CGContext, font: CTFont?, glass: Bool, title: CFString?, icon: CGImage?, rect: CGRect, color: CGColor)
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
            line = fittedLine(title, attributes: attributes, maxWidth: textMaxWidth)
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

    static func title(for wid: WindowID?) -> CFString?
    {
        guard let wid, let target = WindowManager.shared.window(for: wid) else { return nil }
        if let title = target.title, CFStringGetLength(title) > 0 { return title }
        if let app = target.application { return app.name as CFString }
        return nil
    }

    //
    // NOTE: The application icon of a window, loaded once per application and owned by it.
    //
    static func icon(for wid: WindowID?) -> CGImage?
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

    static func separatorColor(for text: RGBAColor) -> RGBAColor
    {
        var text = text
        text.a *= 0.25
        return text
    }

    private func draw(_ entries: UnsafeMutablePointer<TabBarEntry>, count: Int)
    {
        SLSDisableUpdate(SLS.connection)
        defer { SLSReenableUpdate(SLS.connection) }
        guard let context else { return }
        let bounds = CGRect(origin: .zero, size: frame.size)
        context.clear(bounds)
        for i in 0..<count {
            let entry = entries[i]
            let (background, text) = entry.state.colors
            let tab = TabBar.slot(in: bounds, index: i, count: count)
            context.setFillColor(red: CGFloat(background.r), green: CGFloat(background.g), blue: CGFloat(background.b), alpha: CGFloat(background.a))
            context.fill(tab)
            if i > 0 {
                let separator = TabBar.separatorColor(for: text)
                context.setFillColor(red: CGFloat(separator.r), green: CGFloat(separator.g), blue: CGFloat(separator.b), alpha: CGFloat(separator.a))
                context.fill(CGRect(x: tab.minX, y: 0, width: 1, height: bounds.height))
            }
            if entry.title != nil || entry.icon != nil {
                TabBar.drawTitle(in: context, font: WindowManager.shared.tabBarFont, glass: false, title: entry.title, icon: entry.icon, rect: tab, color: text.cgColor)
            }
        }
        context.flush()
    }

    private static var usesGlass: Bool { WindowManager.shared.tabBarStyle == .glass }

    static var cardPadding: Int
    {
        if !usesGlass || WindowManager.shared.tabBarBackdrop == .off { return 0 }
        return WindowManager.shared.tabBarCardPadding
    }

    private var exists: Bool { id != nil || glass != nil }

    private func create(_ frame: CGRect)
    {
        self.frame = frame
        tabBarList.append(self)
        if TabBar.usesGlass { return }
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
        SLSNewWindow(SLS.connection, 2, 0, 0, shape, &barID)
        id = WindowID(nonzero: barID)
        guard let id else { return }
        var tags: UInt64 = (1 << 1) | (1 << 9)
        SLSSetWindowTags(SLS.connection, id.rawValue, &tags, 64)
        SLS.disableShadow(id.rawValue)
        SLSSetWindowResolution(SLS.connection, id.rawValue, 2)
        SLSSetWindowOpacity(SLS.connection, id.rawValue, false)
        context = SLWindowContextCreate(SLS.connection, id.rawValue, nil)
    }

    //
    // NOTE: Ordering a bar in can still move it to the active space, so its space is checked after every order and
    // fixed up when it no longer matches the space of the window it sits above.
    //
    private func keepOnSpace()
    {
        guard let id, let sid, id.space != sid else { return }
        TabBarGlass.moveWindow(id, to: sid)
    }

    //
    // NOTE: Creates the bar window if needed, moves it to the frame and to the space of the window it
    // sits above, draws the entries and orders it right above that window (right below it for a glass bar
    // with a backdrop card, which then covers the whole card). Titles stay owned by the caller.
    //
    func render(frame: CGRect, card: CGRect, above aboveWid: WindowID?, entries: UnsafeMutablePointer<TabBarEntry>, count entryCount: Int)
    {
        self.card = card
        // NOTE: A bar without a window to sit above has nothing to be ordered against; it is hidden.
        guard let aboveWid else { hide(); return }
        let count = min(entryCount, TabBar.maxEntryCount)
        if !exists { create(frame) }
        else if frame != self.frame {
            if let id {
                var frame = frame
                var region: CFTypeRef?
                CGSNewRegionWithRect(&frame, &region)
                let shape = region!
                SLSDisableUpdate(SLS.connection)
                SLSSetWindowShape(SLS.connection, id.rawValue, 0, 0, shape)
                SLSReenableUpdate(SLS.connection)
            }
            self.frame = frame
        }
        if let space = aboveWid.space, space != sid {
            if let id { TabBarGlass.moveWindow(id, to: space) }
            sid = space
        }
        aboveWindowID = aboveWid
        hidden = false
        self.entryCount = count
        entryWindowIDs = (0..<count).map { entries[$0].focusWindowID }
        if let id {
            draw(entries, count: count)
            SLSSetWindowLevel(SLS.connection, id.rawValue, aboveWid.level)
            SLSSetWindowSubLevel(SLS.connection, id.rawValue, aboveWid.subLevel)
            SLSOrderWindow(SLS.connection, id.rawValue, 1, aboveWid.rawValue)
            keepOnSpace()
        } else { renderGlass(above: aboveWid, entries: entries, count: count) }
        TabBar.publishHits()
    }

    func hide()
    {
        if !exists || hidden { return }
        if let id { SLSOrderWindow(SLS.connection, id.rawValue, 0, 0) }
        else { hideGlass() }
        hidden = true
        TabBar.publishHits()
    }

    func destroy()
    {
        if !exists { return }
        if let i = tabBarList.firstIndex(of: self) { tabBarList.remove(at: i) }
        if let id {
            SLSOrderWindow(SLS.connection, id.rawValue, 0, 0)
            context = nil
            SLSReleaseWindow(SLS.connection, id.rawValue)
        } else { destroyGlass() }
        reset()
        TabBar.publishHits()
    }

    //
    // NOTE: Window id of the backdrop card of a visible bar, or nil when it has none (yet). The panel is created on the
    // main queue, so the id only becomes known after the first update of the bar reaches it.
    //
    var cardID: WindowID?
    {
        if hidden || glass == nil { return nil }
        if !TabBar.usesGlass || WindowManager.shared.tabBarBackdrop == .off { return nil }
        return glassPanelID
    }

    static func orderBars(above wid: WindowID)
    {
        for bar in outerFirst(tabBarList.filter { !$0.hidden && $0.aboveWindowID == wid }) {
            if let id = bar.id {
                SLSOrderWindow(SLS.connection, id.rawValue, 1, wid.rawValue)
                bar.keepOnSpace()
            } else { bar.orderGlass(above: wid) }
        }
    }

    // NOTE: Ordering each card below the same window puts the last card in front. Creation order changes when
    // layouts or styles are rebuilt, so nested cards must explicitly be ordered from the outermost inward.
    static func outerFirst(_ bars: [TabBar]) -> [TabBar]
    {
        bars.sorted { $0.card.width * $0.card.height > $1.card.width * $1.card.height }
    }

    static func redrawAll()
    {
        for bar in outerFirst(tabBarList) { bar.owner?.renderBar() }
    }

    static func refresh(for wid: WindowID?)
    {
        guard let wid, let owner = WindowManager.shared.managedWindows[wid] else { return }
        if owner.layout != .tree { return }
        View.refreshBars(forWindowID: wid)
    }

    //
    // NOTE: Called after a tab bar config change that affects the layout. Drops every bar so that the next layout pass
    // recreates them with the new settings, then re-lays out all views to apply the new window area.
    //
    static func refreshAll()
    {
        for owner in SpaceManager.shared.views.values.sorted(by: { $0.sid < $1.sid }) where owner.layout == .tree {
            owner.tree?.releaseBars()
            owner.updateAndFlush()
        }
        publishHits()
    }
}
