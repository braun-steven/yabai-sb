import AppKit
import CPrivate

//
// NOTE: The AppKit side of the glass tab bars. AppKit must be used from the main thread, so the event loop hands a
// snapshot of a bar to the main queue. Every pending block retains the bar, so releasing a bar never frees a panel
// that is still in use. Swift ownership keeps that handoff independent of the container's lifetime.
//

private struct Entry
{
    let windowID: UInt32
    let title: CFString?
    let icon: CGImage?
    let text: CGColor
    let active: Bool
    let customText: Bool
}

//
// NOTE: Immutable after init, so it can be handed to the main queue.
//

private struct Snapshot: @unchecked Sendable
{
    let frame: CGRect
    let card: CGRect
    let backdrop: tab_bar_backdrop
    let appearance: TabBarAppearance
    let cardRadius: CGFloat
    let sid: UInt64
    let aboveWid: UInt32
    let level: Int32
    let subLevel: Int32
    let font: CTFont?
    let trackTint: CGColor
    let backdropTint: CGColor
    let pillTint: CGColor
    let customTrack: Bool
    let customBackdrop: Bool
    let customPill: Bool
    let focused: Bool
    let entries: [Entry]

    // NOTE: The glass style uses the Liquid Glass material of macOS 26, which the window server only renders for
    // AppKit views. Each bar is therefore a borderless panel owned by AppKit instead of a raw SkyLight window.
    // This side runs on the event loop: it takes a snapshot of a bar and hands it to the main queue.
    init(_ bar: TabBar, _ aboveWid: UInt32, _ list: UnsafeMutablePointer<TabBarEntry>, _ count: Int32)
    {
        let wm = window_manager_global()
        frame = bar.frame
        card = bar.card
        backdrop = wm.tab_bar_backdrop
        appearance = wm.tab_bar_appearance
        cardRadius = CGFloat(wm.tab_bar_window_radius) + (frame.minX - card.minX)
        sid = bar.sid
        self.aboveWid = aboveWid
        level = window_level(aboveWid)
        subLevel = window_sub_level(aboveWid)
        font = wm.tab_bar_font
        let track = tab_bar_glass_tint(wm.tab_bar_unfocused_color, wm.tab_bar_unfocused_color_custom, 0.4)
        trackTint = tabBarCGColor(track)
        backdropTint = tabBarCGColor(tab_bar_glass_tint(wm.tab_bar_backdrop_color, wm.tab_bar_backdrop_color_custom, 0.4))
        var pill = track
        var customPill = false
        var focused = false
        var entries: [Entry] = []
        for i in 0..<Int(count) {
            let source = list[i]
            let (background, text) = tabBarStateColors(source.state)
            let customText = source.state == TAB_BAR_FOCUSED ? wm.tab_bar_focused_text_color_custom
                           : source.state == TAB_BAR_INACTIVE ? wm.tab_bar_inactive_text_color_custom
                           : wm.tab_bar_unfocused_text_color_custom
            entries.append(Entry(windowID: source.focus_wid, title: source.title, icon: source.icon, text: tabBarCGColor(text), active: source.state != TAB_BAR_UNFOCUSED, customText: customText))
            if source.state == TAB_BAR_FOCUSED {
                pill = tab_bar_glass_tint(background, wm.tab_bar_focused_color_custom, 0.8)
                customPill = wm.tab_bar_focused_color_custom
                focused = true
            } else if source.state == TAB_BAR_INACTIVE {
                pill = tab_bar_glass_tint(background, wm.tab_bar_inactive_color_custom, 0.8)
                customPill = wm.tab_bar_inactive_color_custom
            }
        }
        self.entries = entries
        pillTint = tabBarCGColor(pill)
        customTrack = wm.tab_bar_unfocused_color_custom
        customBackdrop = wm.tab_bar_backdrop_color_custom
        self.customPill = customPill
        self.focused = focused
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

func tabBarGlassInnerRect(_ bounds: CGRect) -> CGRect
{
    let inset = min(CGFloat(TAB_BAR_GLASS_PILL_INSET), max(0, min(bounds.width, bounds.height) * 0.5))
    return trackRect(bounds).insetBy(dx: inset, dy: inset)
}

@MainActor
private final class TabButton: NSButton
{
    var windowID: UInt32 = 0
    var icon: CGImage?

    init()
    {
        super.init(frame: .zero)
        setButtonType(.momentaryChange)
        isBordered = false
        controlSize = .small
        imagePosition = .imageLeading
        imageHugsTitle = true
        imageScaling = .scaleProportionallyDown
        alignment = .center
        focusRingType = .none
        cell?.lineBreakMode = .byTruncatingTail
        wantsLayer = true
        target = self
        action = #selector(selectTab)
        setAccessibilityRole(.radioButton)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    @objc private func selectTab()
    {
        EventLoop.post(.tabBarClicked(windowID: windowID))
    }
}

@MainActor
private final class Root: NSView
{
    var refresh: (() -> Void)?

    override func viewDidChangeEffectiveAppearance()
    {
        super.viewDidChangeEffectiveAppearance()
        refresh?()
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
    let root = Root(frame: .zero)
    let glassContainer = NSGlassEffectContainerView(frame: .zero)
    let controls = NSView(frame: .zero)
    let trackTint = makeTint()
    let track = NSGlassEffectView(frame: .zero)
    let pillTint = makeTint()
    let pill = NSGlassEffectView(frame: .zero)
    let content = NSView(frame: .zero)
    let feedback = makeTint()
    var buttons: [TabButton] = []
    var separators: [NSView] = []
    var snapshot: Snapshot?
    var pointerWindowID: UInt32?
    var pressed = false
    var accessibilityObserver: NSObjectProtocol?
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

        panel.appearance = NSAppearance(named: .darkAqua)
        panel.collectionBehavior = [.managed, .ignoresCycle, .fullScreenAuxiliary]

        trackTint.autoresizingMask = [.width, .height]
        track.contentView = trackTint
        track.effectIsInteractive = true
        pill.effectIsInteractive = true

        glassContainer.spacing = 0
        glassContainer.contentView = controls
        root.addSubview(glassContainer)
        controls.addSubview(track)
        trackTint.addSubview(pillTint)
        trackTint.addSubview(pill)
        trackTint.addSubview(content)
        content.addSubview(feedback)
        feedback.isHidden = true
        content.setAccessibilityRole(.tabGroup)
        content.setAccessibilityElement(true)
        content.setAccessibilityLabel("Window tabs")
        panel.contentView = root
        root.refresh = { [weak self] in self?.refresh() }
        accessibilityObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
    }

    func close()
    {
        if let accessibilityObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(accessibilityObserver)
            self.accessibilityObserver = nil
        }
        root.refresh = nil
        snapshot = nil
        panel.orderOut(nil)
        panel.close()
    }

    private func refresh()
    {
        guard let snapshot else { return }
        panel.effectiveAppearance.performAsCurrentDrawingAppearance {
            layout(snapshot, animate: false)
        }
    }

    private func resolvedTint(_ configured: CGColor, custom: Bool, fallback: NSColor) -> CGColor
    {
        let color = snapshot?.appearance == .system && !custom ? fallback.cgColor : configured
        return NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency ? color.copy(alpha: 1) ?? color : color
    }

    func pointer(windowID: UInt32?, pressed: Bool)
    {
        pointerWindowID = windowID
        self.pressed = pressed
        updatePointer()
    }

    private func updatePointer()
    {
        panel.effectiveAppearance.performAsCurrentDrawingAppearance {
            let hovered = buttons.first { $0.windowID == pointerWindowID }
            feedback.isHidden = hovered == nil
            if let hovered {
                feedback.frame = hovered.frame
                setTint(feedback, radius: hovered.frame.height * 0.5,
                        color: NSColor.labelColor.withAlphaComponent(pressed ? 0.16 : 0.08).cgColor)
            }
            for button in buttons {
                button.highlight(button === hovered && pressed)
            }
        }
    }

    private func layoutContent(_ snapshot: Snapshot, inner: CGRect, animate: Bool)
    {
        let previous = buttons
        buttons = snapshot.entries.map { entry in
            previous.first { $0.windowID == entry.windowID } ?? TabButton()
        }
        for button in previous where !buttons.contains(where: { $0 === button }) { button.removeFromSuperview() }
        for separator in separators { separator.removeFromSuperview() }
        separators.removeAll(keepingCapacity: true)

        let contrast = NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast
        for (index, entry) in snapshot.entries.enumerated() {
            let button = buttons[index]
            let slot = tab_bar_slot(inner, Int32(index), Int32(buttons.count))
            let title = entry.title.map { $0 as String } ?? ""
            let color = entry.customText ? NSColor(cgColor: entry.text) ?? .labelColor
                      : entry.active || contrast ? NSColor.labelColor : NSColor.secondaryLabelColor
            if animate && (button.title != title || button.contentTintColor != color) {
                let transition = CATransition()
                transition.type = .fade
                transition.duration = TAB_BAR_GLASS_ANIMATION_DURATION
                button.layer?.add(transition, forKey: "tabContent")
            } else if !animate {
                button.layer?.removeAnimation(forKey: "tabContent")
            }
            button.windowID = entry.windowID
            button.title = title
            button.font = snapshot.font.map { $0 as NSFont }
            button.contentTintColor = color
            if entry.customText {
                button.attributedTitle = NSAttributedString(string: title, attributes: [
                    .foregroundColor: color, .font: button.font ?? NSFont.systemFont(ofSize: 12)
                ])
            }
            button.setAccessibilityLabel(title)
            button.setAccessibilityValue(entry.active ? 1 : 0)
            button.toolTip = title
            let iconSize = max(0, min(16, slot.height - 4))
            let showIcon = entry.icon != nil && iconSize > 0 && slot.width >= iconSize + 16
            if button.icon !== entry.icon || button.image?.size.height != iconSize {
                button.icon = entry.icon
                button.image = entry.icon.map { NSImage(cgImage: $0, size: NSSize(width: iconSize, height: iconSize)) }
            }
            button.imagePosition = showIcon ? (slot.width >= iconSize + 40 ? .imageLeading : .imageOnly) : .noImage
            button.frame = slot.insetBy(dx: min(4, slot.width * 0.5), dy: 0)
            button.layer?.cornerRadius = slot.height * 0.5
            if button.superview == nil { content.addSubview(button) }

            if index > 0 && !entry.active && !snapshot.entries[index - 1].active {
                let separator = makeTint()
                let height = floor(inner.height * 0.45)
                let scale = panel.backingScaleFactor
                separator.frame = CGRect(x: slot.minX, y: inner.midY - height * 0.5, width: 1 / scale, height: height)
                separator.layer?.backgroundColor = NSColor.separatorColor.cgColor
                content.addSubview(separator)
                separators.append(separator)
            }
        }
        updatePointer()
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
        setTint(backdropTint, radius: snapshot.cardRadius, color: resolvedTint(snapshot.backdropTint, custom: snapshot.customBackdrop, fallback: NSColor.windowBackgroundColor.withAlphaComponent(0.4)))

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
        glassContainer.frame = bounds
        controls.frame = bounds
        layoutBackdrop(snapshot, bounds: bounds)

        track.frame = trackFrame
        trackTint.frame = track.bounds
        track.cornerRadius = trackFrame.height * 0.5
        setTint(trackTint, radius: trackFrame.height * 0.5, color: resolvedTint(snapshot.trackTint, custom: snapshot.customTrack, fallback: NSColor.controlBackgroundColor.withAlphaComponent(0.4)))
        content.frame = track.bounds
        let inner = tabBarGlassInnerRect(strip).offsetBy(dx: -trackFrame.minX, dy: -trackFrame.minY)
        layoutContent(snapshot, inner: inner, animate: animate)
        let contrast = NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast
        trackTint.layer?.borderWidth = contrast ? 1 : 0
        trackTint.layer?.borderColor = NSColor.labelColor.withAlphaComponent(0.6).cgColor

        pill.isHidden = active == nil
        pillTint.isHidden = active == nil
        guard let active else { return }

        let pillFrame = tab_bar_slot(inner, Int32(active), Int32(snapshot.entries.count))
        pill.cornerRadius = pillFrame.height * 0.5
        let pillColor = snapshot.focused ? NSColor.controlAccentColor.withAlphaComponent(0.65) : NSColor.selectedContentBackgroundColor.withAlphaComponent(0.35)
        setTint(pillTint, radius: pillFrame.height * 0.5, color: resolvedTint(snapshot.pillTint, custom: snapshot.customPill, fallback: pillColor))
        pillTint.layer?.borderWidth = contrast ? 1 : 0
        pillTint.layer?.borderColor = NSColor.labelColor.withAlphaComponent(0.8).cgColor

        if animate && pill.frame != pillFrame {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = TAB_BAR_GLASS_ANIMATION_DURATION
                context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                context.allowsImplicitAnimation = true
                self.pillTint.animator().frame = pillFrame
                self.pill.animator().frame = pillFrame
            }
        } else {
            pill.layer?.removeAllAnimations()
            pillTint.layer?.removeAllAnimations()
            pillTint.frame = pillFrame
            pill.frame = pillFrame
        }
    }

    func apply(_ snapshot: Snapshot)
    {
        let previous = self.snapshot
        self.snapshot = snapshot
        panel.appearance = snapshot.appearance == .dark ? NSAppearance(named: .darkAqua) : nil
        below = snapshot.hasCard
        let frame = below ? snapshot.card : snapshot.frame
        let primaryHeight = CGDisplayBounds(CGMainDisplayID()).height
        let cocoaFrame = NSRect(x: frame.minX, y: primaryHeight - frame.minY - frame.height, width: frame.width, height: frame.height)

        let visible = panel.isVisible
        let resized = panel.frame.size != cocoaFrame.size

        NSAnimationContext.beginGrouping()
        NSAnimationContext.current.duration = 0
        panel.setFrame(cocoaFrame, display: false)
        let animate = visible && !resized && previous?.entries.map(\.windowID) == snapshot.entries.map(\.windowID)
                   && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        panel.effectiveAppearance.performAsCurrentDrawingAppearance {
            layout(snapshot, animate: animate)
        }
        NSAnimationContext.endGrouping()

        tab_bar_glass_move_to_space(id, snapshot.sid)
        // NOTE: Keep AppKit's order in sync with SkyLight even for visible panels. Otherwise a newly created
        // outer card can be put back above an existing inner card when AppKit next displays its windows.
        panel.order(below ? .below : .above, relativeTo: Int(snapshot.aboveWid))
        tab_bar_glass_move_to_space(id, snapshot.sid)

        tab_bar_glass_set_level(id, snapshot.level, snapshot.subLevel)
        tab_bar_glass_order_panel(id, below, snapshot.aboveWid)
    }

    func order(_ wid: UInt32)
    {
        guard panel.isVisible else { return }
        panel.order(below ? .below : .above, relativeTo: Int(wid))
        if let snapshot { tab_bar_glass_move_to_space(id, snapshot.sid) }
        tab_bar_glass_order_panel(id, below, wid)
    }
}

//
// NOTE: The object is created on the event loop thread, but AppKit only allows windows and views on the main thread.
// The panel is therefore created by the first update that reaches the main queue. Until then hide and order are no-ops,
// and the id of the panel is 0.
//

final class TabBarGlass: @unchecked Sendable
{
    private let lock = NSLock()
    private var panelId: UInt32 = 0
    private var panel: Panel? // main queue only

    var id: UInt32 { lock.withLock { panelId } }

    @MainActor
    fileprivate func apply(_ snapshot: Snapshot)
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
        panel?.pointer(windowID: nil, pressed: false)
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
        lock.withLock { panelId = 0 }
    }

    func pointer(windowID: UInt32?, pressed: Bool)
    {
        onMain { $0.panel?.pointer(windowID: windowID, pressed: pressed) }
    }

    fileprivate func onMain(_ body: @escaping @MainActor @Sendable (TabBarGlass) -> Void)
    {
        DispatchQueue.main.async {
            MainActor.assumeIsolated { body(self) }
        }
    }
}

//
// NOTE: Glass is translucent, so a background color that was never configured is applied as a tint of the i3 color
// with the given alpha instead of the opaque i3 color itself. A configured color is used exactly as given.
//
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

func tab_bar_glass_render(_ bar: TabBar, _ aboveWid: UInt32, _ entries: UnsafeMutablePointer<TabBarEntry>, _ count: Int32)
{
    let snapshot = Snapshot(bar, aboveWid, entries, count)
    if bar.glass == nil { bar.glass = TabBarGlass() }
    bar.glass!.onMain { $0.apply(snapshot) }
}

func tab_bar_glass_hide(_ bar: TabBar)
{
    bar.glass?.onMain { $0.hide() }
}

func tab_bar_glass_order(_ bar: TabBar, _ wid: UInt32)
{
    bar.glass?.onMain { $0.order(wid) }
}

func tab_bar_glass_release(_ bar: TabBar)
{
    // NOTE: FIFO main-queue delivery closes the panel after pending updates; each block retains its owner.
    bar.glass?.onMain { $0.close() }
    bar.glass = nil
}

func tab_bar_glass_panel_id(_ bar: TabBar) -> UInt32
{
    bar.glass?.id ?? 0
}
