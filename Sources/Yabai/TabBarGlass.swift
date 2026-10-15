import AppKit
import YabaiC
import CPrivate

//
// NOTE: The AppKit side of the glass tab bars. AppKit must be used from the main thread, so the event loop hands a
// snapshot of a bar to the main queue. Every pending block retains the bar, so releasing a bar never frees a panel
// that is still in use. The C interface is declared in tab_bar_glass.h.
//

private struct Entry
{
    let title: CFString?
    let icon: CGImage?
    let text: CGColor
    let active: Bool
}

//
// NOTE: Immutable after init, so it can be handed to the main queue.
//

private struct Snapshot: @unchecked Sendable
{
    let frame: CGRect
    let card: CGRect
    let backdrop: tab_bar_backdrop
    let cardRadius: CGFloat
    let sid: UInt64
    let aboveWid: UInt32
    let level: Int32
    let subLevel: Int32
    let font: CTFont?
    let trackTint: CGColor
    let backdropTint: CGColor
    let pillTint: CGColor
    let separator: CGColor
    let entries: [Entry]

    // NOTE: The glass style uses the Liquid Glass material of macOS 26, which the window server only renders for
    // AppKit views. Each bar is therefore a borderless panel owned by AppKit instead of a raw SkyLight window.
    // This side runs on the event loop: it takes a snapshot of a bar and hands it to the main queue.
    init(_ bar: UnsafeMutablePointer<tab_bar>, _ aboveWid: UInt32, _ list: UnsafeMutablePointer<tab_bar_entry>, _ count: Int32)
    {
        let wm = window_manager_global()!.pointee
        frame = bar.pointee.frame
        card = bar.pointee.card
        backdrop = wm.tab_bar_backdrop
        cardRadius = CGFloat(wm.tab_bar_window_radius) + (frame.minX - card.minX)
        sid = bar.pointee.sid
        self.aboveWid = aboveWid
        level = window_level(aboveWid)
        subLevel = window_sub_level(aboveWid)
        font = wm.tab_bar_font?.takeUnretainedValue()
        let track = tab_bar_glass_tint(wm.tab_bar_unfocused_color, wm.tab_bar_unfocused_color_custom, 0.4)
        trackTint = tabBarCGColor(track)
        backdropTint = tabBarCGColor(tab_bar_glass_tint(wm.tab_bar_backdrop_color, wm.tab_bar_backdrop_color_custom, 0.4))
        separator = tabBarCGColor(tabBarSeparatorColor(wm.tab_bar_unfocused_text_color))
        var pill = track
        var entries: [Entry] = []
        for i in 0..<Int(count) {
            let source = list[i]
            let (background, text) = tabBarStateColors(source.state)
            entries.append(Entry(title: source.title?.takeUnretainedValue(), icon: source.icon?.takeUnretainedValue(), text: tabBarCGColor(text), active: source.state != TAB_BAR_UNFOCUSED))
            if source.state == TAB_BAR_FOCUSED {
                pill = tab_bar_glass_tint(background, wm.tab_bar_focused_color_custom, 0.8)
            } else if source.state == TAB_BAR_INACTIVE {
                pill = tab_bar_glass_tint(background, wm.tab_bar_inactive_color_custom, 0.8)
            }
        }
        self.entries = entries
        pillTint = tabBarCGColor(pill)
    }

    var hasCard: Bool { backdrop != TAB_BAR_BACKDROP_OFF }
}

private func trackRect(_ bounds: CGRect) -> CGRect
{
    var track = bounds
    track.origin.y += CGFloat(TAB_BAR_GLASS_TRACK_MARGIN)
    track.size.height -= CGFloat(TAB_BAR_GLASS_TRACK_MARGIN)
    return track.height <= 2 * CGFloat(TAB_BAR_GLASS_PILL_INSET) ? bounds : track
}

private func innerRect(_ bounds: CGRect) -> CGRect
{
    trackRect(bounds).insetBy(dx: CGFloat(TAB_BAR_GLASS_PILL_INSET), dy: CGFloat(TAB_BAR_GLASS_PILL_INSET))
}

@MainActor
private final class Content: NSView
{
    var snapshot: Snapshot?

    override var isOpaque: Bool { false }

    override func draw(_ dirtyRect: NSRect)
    {
        guard let snapshot, !snapshot.entries.isEmpty, let context = NSGraphicsContext.current?.cgContext else { return }

        let inner = innerRect(bounds)
        let separatorHeight = CGFloat(Int(inner.height * 0.5))
        let count = Int32(snapshot.entries.count)

        for (i, entry) in snapshot.entries.enumerated() {
            let tab = tab_bar_slot(inner, Int32(i), count)

            if i > 0 && !entry.active && !snapshot.entries[i - 1].active {
                let y = CGFloat(Int(inner.minY + (inner.height - separatorHeight) * 0.5))
                context.setFillColor(snapshot.separator)
                context.fill(CGRect(x: tab.minX, y: y, width: 1, height: separatorHeight))
            }

            if entry.title != nil || entry.icon != nil {
                tab_bar_draw_title(context, snapshot.font, true, entry.title, entry.icon, tab, entry.text)
            }
        }
    }
}

//
// NOTE: The tints are rounded layers instead of NSGlassEffectView.tintColor, because AppKit draws glass in its
// desaturated inactive look in an app that is never active, which hides most of the tint color. The pill tint sits
// below the pill, so the glass refracts and frosts it like tinted glass and keeps its edge highlight. The track tint
// sits on top of the track instead, because the glass would lighten a dark color beneath it.
//

@MainActor
private func makeTint() -> NSView
{
    let tint = NSView(frame: .zero)
    tint.wantsLayer = true
    return tint
}

@MainActor
private func setTint(_ tint: NSView, radius: CGFloat, color: CGColor)
{
    tint.layer?.backgroundColor = color
    tint.layer?.cornerRadius = radius
}

//
// NOTE: NSVisualEffectView only rounds its material through a mask image. A stretchable rounded rect keeps the
// corners at the given radius for any size of the card.
//

@MainActor
private func makeMask(radius: CGFloat) -> NSImage
{
    let size = 2 * radius + 1
    let mask = NSImage(size: NSSize(width: size, height: size), flipped: false) { rect in
        NSColor.black.setFill()
        NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius).fill()
        return true
    }
    mask.capInsets = NSEdgeInsets(top: radius, left: radius, bottom: radius, right: radius)
    mask.resizingMode = .stretch
    return mask
}

//
// NOTE: The panel of a bar and its views, created by the first update that reaches the main queue.
//

@MainActor
private final class Panel
{
    let panel = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
    let root = NSView(frame: .zero)
    let trackTint = makeTint()
    let track = NSGlassEffectView(frame: .zero)
    let pillTint = makeTint()
    let pill = NSGlassEffectView(frame: .zero)
    let content = Content(frame: .zero)
    var backdrop: NSView?
    var backdropTint: NSView?
    var backdropKind = TAB_BAR_BACKDROP_OFF
    var backdropRadius: CGFloat = 0
    var below = false

    var id: UInt32 { UInt32(panel.windowNumber) }

    init()
    {
        panel.isReleasedWhenClosed = false
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.ignoresMouseEvents = true
        panel.animationBehavior = .none

        //
        // NOTE: Glass follows the appearance of its window and turns whiter in light mode, which would wash out the
        // tints. The panel is pinned to the dark appearance so the bar looks the same in light and dark mode.
        //

        panel.appearance = NSAppearance(named: .darkAqua)
        panel.collectionBehavior = [.managed, .ignoresCycle, .fullScreenAuxiliary]

        trackTint.autoresizingMask = [.width, .height]
        track.contentView = trackTint

        root.addSubview(track)
        root.addSubview(pillTint)
        root.addSubview(pill)
        root.addSubview(content)
        panel.contentView = root
    }

    func close()
    {
        panel.orderOut(nil)
        panel.close()
    }

    //
    // NOTE: The backdrop is a rounded card behind the whole tabbed container. The panel covers the card and is ordered
    // below the active window, so the window sits inside the card with the bar above it, and the card hides the other
    // tabs of the container. The card has its own tint, so the track of the bar stays visible on top of it.
    //

    private func setBackdrop(_ kind: tab_bar_backdrop)
    {
        guard kind != backdropKind else { return }

        backdrop?.removeFromSuperview()
        backdrop = nil
        backdropTint = nil
        backdropKind = kind
        backdropRadius = -1

        guard kind != TAB_BAR_BACKDROP_OFF else { return }

        let tint = makeTint()
        tint.autoresizingMask = [.width, .height]

        let view: NSView
        if kind == TAB_BAR_BACKDROP_GLASS {
            let glass = NSGlassEffectView(frame: .zero)
            glass.contentView = tint
            view = glass
        } else {
            let effect = NSVisualEffectView(frame: .zero)
            effect.material = .hudWindow
            effect.blendingMode = .behindWindow
            effect.state = .active
            effect.addSubview(tint)
            view = effect
        }

        root.addSubview(view, positioned: .below, relativeTo: nil)
        backdrop = view
        backdropTint = tint
    }

    private func layoutBackdrop(_ snapshot: Snapshot, bounds: NSRect)
    {
        setBackdrop(snapshot.backdrop)
        guard let backdrop, let backdropTint else { return }

        backdrop.frame = bounds
        backdropTint.frame = backdrop.bounds
        setTint(backdropTint, radius: snapshot.cardRadius, color: snapshot.backdropTint)

        guard backdropRadius != snapshot.cardRadius else { return }
        backdropRadius = snapshot.cardRadius

        if let glass = backdrop as? NSGlassEffectView {
            glass.cornerRadius = backdropRadius
        } else if let effect = backdrop as? NSVisualEffectView {
            effect.maskImage = makeMask(radius: backdropRadius)
        }
    }

    private func layout(_ snapshot: Snapshot, animate: Bool)
    {
        let frame = snapshot.frame
        let card = snapshot.card
        let bounds = NSRect(origin: .zero, size: snapshot.hasCard ? card.size : frame.size)
        let strip = snapshot.hasCard
                  ? NSRect(x: frame.minX - card.minX, y: card.height - (frame.minY - card.minY) - frame.height, width: frame.width, height: frame.height)
                  : bounds
        let trackFrame = trackRect(strip)
        let active = snapshot.entries.firstIndex { $0.active }

        root.frame = bounds
        layoutBackdrop(snapshot, bounds: bounds)

        track.frame = trackFrame
        track.cornerRadius = trackFrame.height * 0.5
        setTint(trackTint, radius: trackFrame.height * 0.5, color: snapshot.trackTint)
        content.frame = strip

        pill.isHidden = active == nil
        pillTint.isHidden = active == nil
        guard let active else { return }

        let pillFrame = tab_bar_slot(innerRect(strip), Int32(active), Int32(snapshot.entries.count))
        pill.cornerRadius = pillFrame.height * 0.5
        setTint(pillTint, radius: pillFrame.height * 0.5, color: snapshot.pillTint)

        if animate && pill.frame != pillFrame {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = TAB_BAR_GLASS_ANIMATION_DURATION
                context.allowsImplicitAnimation = true
                self.pillTint.animator().frame = pillFrame
                self.pill.animator().frame = pillFrame
            }
        } else {
            pillTint.frame = pillFrame
            pill.frame = pillFrame
        }
    }

    func apply(_ snapshot: Snapshot)
    {
        below = snapshot.hasCard
        let frame = below ? snapshot.card : snapshot.frame
        let primaryHeight = CGDisplayBounds(CGMainDisplayID()).height
        let cocoaFrame = NSRect(x: frame.minX, y: primaryHeight - frame.minY - frame.height, width: frame.width, height: frame.height)

        let visible = panel.isVisible
        let resized = panel.frame.size != cocoaFrame.size

        NSAnimationContext.beginGrouping()
        NSAnimationContext.current.duration = 0
        panel.setFrame(cocoaFrame, display: false)
        layout(snapshot, animate: visible && !resized)
        NSAnimationContext.endGrouping()

        content.snapshot = snapshot
        content.needsDisplay = true

        tab_bar_glass_move_to_space(id, snapshot.sid)
        if !visible { panel.order(below ? .below : .above, relativeTo: Int(snapshot.aboveWid)) }
        tab_bar_glass_move_to_space(id, snapshot.sid)

        tab_bar_glass_set_level(id, snapshot.level, snapshot.subLevel)
        tab_bar_glass_order_panel(id, below, snapshot.aboveWid)
    }

    func order(_ wid: UInt32)
    {
        guard panel.isVisible else { return }
        tab_bar_glass_order_panel(id, below, wid)
    }
}

//
// NOTE: The object is created on the event loop thread, but AppKit only allows windows and views on the main thread.
// The panel is therefore created by the first update that reaches the main queue. Until then hide and order are no-ops,
// and the id of the panel is 0.
//

private final class TabBarGlass: @unchecked Sendable
{
    private let lock = NSLock()
    private var panelId: UInt32 = 0
    private var panel: Panel? // main queue only

    var id: UInt32 { lock.withLock { panelId } }

    @MainActor
    func apply(_ snapshot: Snapshot)
    {
        let panel = self.panel ?? Panel()
        if self.panel == nil {
            self.panel = panel
            lock.withLock { panelId = panel.id }
        }
        panel.apply(snapshot)
    }

    @MainActor
    func hide()
    {
        panel?.panel.orderOut(nil)
    }

    @MainActor
    func order(_ wid: UInt32)
    {
        panel?.order(wid)
    }

    @MainActor
    func close()
    {
        panel?.close()
        panel = nil
    }
}

private func onMain(_ glass: UnsafeMutableRawPointer, _ body: @escaping @MainActor (TabBarGlass) -> Void)
{
    let bar = Unmanaged<TabBarGlass>.fromOpaque(glass).takeUnretainedValue()
    DispatchQueue.main.async {
        MainActor.assumeIsolated { body(bar) }
    }
}

@_cdecl("tab_bar_glass_create")
func tab_bar_glass_create() -> UnsafeMutableRawPointer?
{
    return Unmanaged.passRetained(TabBarGlass()).toOpaque()
}

private func tabBarGlassApply(_ glass: UnsafeMutableRawPointer, _ snapshot: Snapshot)
{
    onMain(glass) { $0.apply(snapshot) }
}

@_cdecl("tab_bar_glass_hide_panel")
func tab_bar_glass_hide_panel(_ glass: UnsafeMutableRawPointer)
{
    onMain(glass) { $0.hide() }
}

@_cdecl("tab_bar_glass_order_above")
func tab_bar_glass_order_above(_ glass: UnsafeMutableRawPointer, _ wid: UInt32)
{
    onMain(glass) { $0.order(wid) }
}

//
// NOTE: The panel is closed on the main queue after the updates that are still pending, and the last of
// them releases the object.
//

@_cdecl("tab_bar_glass_destroy")
func tab_bar_glass_destroy(_ glass: UnsafeMutableRawPointer)
{
    onMain(glass) { $0.close() }
    Unmanaged<TabBarGlass>.fromOpaque(glass).release()
}

@_cdecl("tab_bar_glass_id")
func tab_bar_glass_id(_ glass: UnsafeMutableRawPointer) -> UInt32
{
    return Unmanaged<TabBarGlass>.fromOpaque(glass).takeUnretainedValue().id
}

//
// NOTE: Glass is translucent, so a background color that was never configured is applied as a tint of the i3 color
// with the given alpha instead of the opaque i3 color itself. A configured color is used exactly as given.
//
@_cdecl("tab_bar_glass_tint")
func tab_bar_glass_tint(_ color: rgba_color, _ custom: Bool, _ alpha: Float) -> rgba_color
{
    var color = color
    if !custom { color.a = alpha }
    return color
}

func tab_bar_glass_move_to_space(_ wid: UInt32, _ sid: UInt64)
{
    let windows = [NSNumber(value: Int32(bitPattern: wid))] as CFArray
    SLSMoveWindowsToManagedSpace(connection_global(), windows, sid)
}

func tab_bar_glass_set_level(_ wid: UInt32, _ level: Int32, _ subLevel: Int32)
{
    SLSSetWindowLevel(connection_global(), wid, level)
    SLSSetWindowSubLevel(connection_global(), wid, subLevel)
}

//
// NOTE: A card ordered below the window lands between the window and its border, so the border is ordered
// right below the window again to stay on top of the card.
//
func tab_bar_glass_order_panel(_ wid: UInt32, _ below: Bool, _ relativeWid: UInt32)
{
    SLSOrderWindow(connection_global(), wid, below ? -1 : 1, relativeWid)
    if below { border_window_ordered(relativeWid) }
}

func tab_bar_glass_render(_ bar: UnsafeMutablePointer<tab_bar>, _ aboveWid: UInt32, _ entries: UnsafeMutablePointer<tab_bar_entry>, _ count: Int32)
{
    let snapshot = Snapshot(bar, aboveWid, entries, count)
    if bar.pointee.glass == nil { bar.pointee.glass = tab_bar_glass_create() }
    tabBarGlassApply(bar.pointee.glass!, snapshot)
}

func tab_bar_glass_hide(_ bar: UnsafeMutablePointer<tab_bar>)
{
    if let glass = bar.pointee.glass { tab_bar_glass_hide_panel(glass) }
}

func tab_bar_glass_order(_ bar: UnsafeMutablePointer<tab_bar>, _ wid: UInt32)
{
    if let glass = bar.pointee.glass { tab_bar_glass_order_above(glass, wid) }
}

func tab_bar_glass_release(_ bar: UnsafeMutablePointer<tab_bar>)
{
    if let glass = bar.pointee.glass { tab_bar_glass_destroy(glass) }
}

func tab_bar_glass_panel_id(_ bar: UnsafeMutablePointer<tab_bar>) -> UInt32
{
    bar.pointee.glass.map { tab_bar_glass_id($0) } ?? 0
}
