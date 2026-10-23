import AppKit
import CPrivate
import Synchronization
import YabaiCore

//
// NOTE: The AppKit side of the glass tab bars. AppKit must be used from the main thread, so the event loop hands a
// snapshot of a bar to the main queue. Every pending block retains the bar, so releasing a bar never frees a panel
// that is still in use. Swift ownership keeps that handoff independent of the container's lifetime.
//

private struct Entry {
  let windowID: WindowID?
  let title: CFString?
  let icon: CGImage?
  let text: CGColor
  let active: Bool
  let customText: Bool
}

//
// NOTE: @unchecked Sendable: CTFont and CFString (the font and the entry titles) are not Sendable, but the snapshot
// only holds immutable CF objects and is immutable after init, so it can be handed to the main queue.
//

private struct Snapshot: @unchecked Sendable {
  let frame: CGRect
  let card: CGRect
  let backdrop: TabBarBackdrop
  let appearance: TabBarAppearance
  let cardRadius: CGFloat
  let sid: SpaceID?
  let aboveWid: WindowID
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
  @WM init(
    _ bar: TabBar, _ aboveWid: WindowID, _ list: UnsafeMutablePointer<TabBarEntry>, _ count: Int
  ) {
    let config = Config.current.tabBar
    frame = bar.frame
    card = bar.card
    backdrop = config.backdrop
    appearance = config.appearance
    cardRadius = CGFloat(config.windowRadius) + (frame.minX - card.minX)
    sid = bar.sid
    self.aboveWid = aboveWid
    level = aboveWid.level
    subLevel = aboveWid.subLevel
    font = WindowManager.shared.tabBarFont
    let track = TabBarGlass.tint(
      config.unfocusedColor, custom: config.unfocusedColorIsCustom, alpha: 0.4)
    trackTint = track.cgColor
    backdropTint =
      TabBarGlass.tint(config.backdropColor, custom: config.backdropColorIsCustom, alpha: 0.4)
      .cgColor
    var pill = track
    var customPill = false
    var focused = false
    var entries: [Entry] = []
    for i in 0..<count {
      let source = list[i]
      let (background, text) = source.state.colors(in: config)
      let customText =
        source.state == .focused
        ? config.focusedTextColorIsCustom
        : source.state == .inactive
          ? config.inactiveTextColorIsCustom
          : config.unfocusedTextColorIsCustom
      entries.append(
        Entry(
          windowID: source.focusWindowID, title: source.title, icon: source.icon,
          text: text.cgColor, active: source.state != .unfocused, customText: customText))
      if source.state == .focused {
        pill = TabBarGlass.tint(background, custom: config.focusedColorIsCustom, alpha: 0.8)
        customPill = config.focusedColorIsCustom
        focused = true
      } else if source.state == .inactive {
        pill = TabBarGlass.tint(background, custom: config.inactiveColorIsCustom, alpha: 0.8)
        customPill = config.inactiveColorIsCustom
      }
    }
    self.entries = entries
    pillTint = pill.cgColor
    customTrack = config.unfocusedColorIsCustom
    customBackdrop = config.backdropColorIsCustom
    self.customPill = customPill
    self.focused = focused
  }

  var hasCard: Bool { backdrop != .off }
}

/// The space above the track of the tabs, the inset of the pill of the active tab and the duration of its move.
private let glassTrackMargin: CGFloat = 2
private let glassPillInset: CGFloat = 2
private let glassAnimationDuration: Double = 0.2

private func trackRect(_ bounds: CGRect) -> CGRect {
  var track = bounds
  track.origin.y += glassTrackMargin
  track.size.height -= glassTrackMargin
  return track.height <= 2 * glassPillInset ? bounds : track
}

@MainActor
private final class TabButton: NSButton {
  var windowID: WindowID?
  var icon: CGImage?

  init() {
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

  @objc private func selectTab() {
    guard let windowID else { return }
    EventLoop.post(.tabBarClicked(windowID: windowID))
  }
}

@MainActor
private final class Root: NSView {
  var refresh: (() -> Void)?

  override func viewDidChangeEffectiveAppearance() {
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
private func makeTint() -> NSView {
  let tint = NSView(frame: .zero)
  tint.wantsLayer = true
  return tint
}

@MainActor
private func setTint(_ tint: NSView, radius: CGFloat, color: CGColor) {
  tint.layer?.backgroundColor = color
  tint.layer?.cornerRadius = radius
}

//
// NOTE: NSVisualEffectView only rounds its material through a mask image. A stretchable rounded rect keeps the
// corners at the given radius for any size of the card.
//

@MainActor
private func makeMask(radius: CGFloat) -> NSImage {
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
private final class Panel {
  let panel = NSPanel(
    contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered,
    defer: false)
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
  var pointerWindowID: WindowID?
  var pressed = false
  var accessibilityObserver: (any NSObjectProtocol)?
  var backdrop: NSView?
  var backdropTint: NSView?
  var backdropKind = TabBarBackdrop.off
  var backdropRadius: CGFloat?
  var below = false

  var id: WindowID { WindowID(UInt32(panel.windowNumber)) }

  init() {
    panel.isReleasedWhenClosed = false
    panel.isOpaque = false
    panel.backgroundColor = .clear
    panel.hasShadow = false
    panel.ignoresMouseEvents = true
    panel.animationBehavior = .none

    panel.appearance = NSAppearance(named: .darkAqua)
    //
    // NOTE: Transient, not managed: Mission Control shows a managed panel as a window of its own, and hides a
    // transient one. Ordering a transient panel in again moves it to the active space; render and order move it back
    // to the space of its window right after.
    //
    panel.collectionBehavior = [.transient, .ignoresCycle, .fullScreenAuxiliary]

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
      forName: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification, object: nil,
      queue: .main
    ) { [weak self] _ in
      MainActor.assumeIsolated { self?.refresh() }
    }
  }

  func close() {
    if let accessibilityObserver {
      NSWorkspace.shared.notificationCenter.removeObserver(accessibilityObserver)
      self.accessibilityObserver = nil
    }
    root.refresh = nil
    snapshot = nil
    panel.orderOut(nil)
    panel.close()
  }

  private func refresh() {
    guard let snapshot else { return }
    panel.effectiveAppearance.performAsCurrentDrawingAppearance {
      layout(snapshot, animate: false)
    }
  }

  private func resolvedTint(_ configured: CGColor, custom: Bool, fallback: NSColor) -> CGColor {
    let color = snapshot?.appearance == .system && !custom ? fallback.cgColor : configured
    return NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency
      ? color.copy(alpha: 1) ?? color : color
  }

  func pointer(windowID: WindowID?, pressed: Bool) {
    pointerWindowID = windowID
    self.pressed = pressed
    updatePointer()
  }

  private func updatePointer() {
    panel.effectiveAppearance.performAsCurrentDrawingAppearance {
      // NOTE: A tab without a window is never hovered, not even while the pointer is on no tab at all (nil).
      let hovered = buttons.first { $0.windowID != nil && $0.windowID == pointerWindowID }
      feedback.isHidden = hovered == nil
      if let hovered {
        feedback.frame = hovered.frame
        setTint(
          feedback, radius: hovered.frame.height * 0.5,
          color: NSColor.labelColor.withAlphaComponent(pressed ? 0.16 : 0.08).cgColor)
      }
      for button in buttons {
        button.highlight(button === hovered && pressed)
      }
    }
  }

  private func layoutContent(_ snapshot: Snapshot, inner: CGRect, animate: Bool) {
    let previous = buttons
    buttons = snapshot.entries.map { entry in
      previous.first { $0.windowID == entry.windowID } ?? TabButton()
    }
    for button in previous where !buttons.contains(where: { $0 === button }) {
      button.removeFromSuperview()
    }
    for separator in separators { separator.removeFromSuperview() }
    separators.removeAll(keepingCapacity: true)

    let contrast = NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast
    for (index, entry) in snapshot.entries.enumerated() {
      let button = buttons[index]
      let slot = TabBar.slot(in: inner, index: index, count: buttons.count)
      let title = entry.title.map { $0 as String } ?? ""
      let color =
        entry.customText
        ? NSColor(cgColor: entry.text) ?? .labelColor
        : entry.active || contrast ? NSColor.labelColor : NSColor.secondaryLabelColor
      if animate && (button.title != title || button.contentTintColor != color) {
        let transition = CATransition()
        transition.type = .fade
        transition.duration = glassAnimationDuration
        button.layer?.add(transition, forKey: "tabContent")
      } else if !animate {
        button.layer?.removeAnimation(forKey: "tabContent")
      }
      button.windowID = entry.windowID
      button.title = title
      button.font = snapshot.font.map { $0 as NSFont }
      button.contentTintColor = color
      if entry.customText {
        button.attributedTitle = NSAttributedString(
          string: title,
          attributes: [
            .foregroundColor: color, .font: button.font ?? NSFont.systemFont(ofSize: 12),
          ])
      }
      button.setAccessibilityLabel(title)
      button.setAccessibilityValue(entry.active ? 1 : 0)
      button.toolTip = title
      let iconSize = max(0, min(16, slot.height - 4))
      let showIcon = entry.icon != nil && iconSize > 0 && slot.width >= iconSize + 16
      if button.icon !== entry.icon || button.image?.size.height != iconSize {
        button.icon = entry.icon
        button.image = entry.icon.map {
          NSImage(cgImage: $0, size: NSSize(width: iconSize, height: iconSize))
        }
      }
      button.imagePosition =
        showIcon ? (slot.width >= iconSize + 40 ? .imageLeading : .imageOnly) : .noImage
      button.frame = slot.insetBy(dx: min(4, slot.width * 0.5), dy: 0)
      button.layer?.cornerRadius = slot.height * 0.5
      if button.superview == nil { content.addSubview(button) }

      if index > 0 && !entry.active && !snapshot.entries[index - 1].active {
        let separator = makeTint()
        let height = floor(inner.height * 0.45)
        let scale = panel.backingScaleFactor
        separator.frame = CGRect(
          x: slot.minX, y: inner.midY - height * 0.5, width: 1 / scale, height: height)
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

  private func setBackdrop(_ kind: TabBarBackdrop) {
    guard kind != backdropKind else { return }

    backdrop?.removeFromSuperview()
    backdrop = nil
    backdropTint = nil
    backdropKind = kind
    backdropRadius = nil

    guard kind != .off else { return }

    let tint = makeTint()
    tint.autoresizingMask = [.width, .height]

    let view: NSView
    if kind == .glass {
      let glass = NSGlassEffectView(frame: .zero)
      glass.contentView = tint
      view = glass
    } else {
      let effect = NSVisualEffectView(frame: .zero)
      effect.material = .underWindowBackground
      effect.blendingMode = .behindWindow
      effect.state = .active
      effect.addSubview(tint)
      view = effect
    }

    root.addSubview(view, positioned: .below, relativeTo: nil)
    backdrop = view
    backdropTint = tint
  }

  private func layoutBackdrop(_ snapshot: Snapshot, bounds: NSRect) {
    setBackdrop(snapshot.backdrop)
    guard let backdrop, let backdropTint else { return }

    backdrop.frame = bounds
    backdropTint.frame = backdrop.bounds
    // NOTE: The standard backdrop supplies its own adaptive color. Only overlay a tint when configured;
    // an opaque semantic backing replaces translucency when requested by the accessibility setting.
    let color: CGColor
    if snapshot.backdrop == .blur && !snapshot.customBackdrop {
      color =
        NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency
        ? NSColor.windowBackgroundColor.cgColor : NSColor.clear.cgColor
    } else {
      color = resolvedTint(
        snapshot.backdropTint, custom: snapshot.customBackdrop,
        fallback: NSColor.windowBackgroundColor.withAlphaComponent(0.4))
    }
    setTint(backdropTint, radius: snapshot.cardRadius, color: color)
    let contrast = NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast
    backdropTint.layer?.borderWidth = contrast ? 1 : 1 / max(1, panel.backingScaleFactor)
    backdropTint.layer?.borderColor =
      contrast
      ? NSColor.labelColor.withAlphaComponent(0.6).cgColor
      : NSColor.separatorColor.cgColor

    guard backdropRadius != snapshot.cardRadius else { return }
    backdropRadius = snapshot.cardRadius

    if let glass = backdrop as? NSGlassEffectView {
      glass.cornerRadius = snapshot.cardRadius
    } else if let effect = backdrop as? NSVisualEffectView {
      effect.maskImage = makeMask(radius: snapshot.cardRadius)
    }
  }

  private func layout(_ snapshot: Snapshot, animate: Bool) {
    let frame = snapshot.frame
    let card = snapshot.card
    let bounds = NSRect(origin: .zero, size: snapshot.hasCard ? card.size : frame.size)
    let strip =
      snapshot.hasCard
      ? NSRect(
        x: frame.minX - card.minX, y: card.height - (frame.minY - card.minY) - frame.height,
        width: frame.width, height: frame.height)
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
    setTint(
      trackTint, radius: trackFrame.height * 0.5,
      color: resolvedTint(
        snapshot.trackTint, custom: snapshot.customTrack,
        fallback: NSColor.controlBackgroundColor.withAlphaComponent(0.4)))
    content.frame = track.bounds
    let inner = TabBarGlass.innerRect(strip).offsetBy(dx: -trackFrame.minX, dy: -trackFrame.minY)
    layoutContent(snapshot, inner: inner, animate: animate)
    let contrast = NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast
    trackTint.layer?.borderWidth = contrast ? 1 : 0
    trackTint.layer?.borderColor = NSColor.labelColor.withAlphaComponent(0.6).cgColor

    pill.isHidden = active == nil
    pillTint.isHidden = active == nil
    guard let active else { return }

    let pillFrame = TabBar.slot(in: inner, index: active, count: snapshot.entries.count)
    pill.cornerRadius = pillFrame.height * 0.5
    let pillColor =
      snapshot.focused
      ? NSColor.controlAccentColor.withAlphaComponent(0.65)
      : NSColor.selectedContentBackgroundColor.withAlphaComponent(0.35)
    setTint(
      pillTint, radius: pillFrame.height * 0.5,
      color: resolvedTint(snapshot.pillTint, custom: snapshot.customPill, fallback: pillColor))
    pillTint.layer?.borderWidth = contrast ? 1 : 0
    pillTint.layer?.borderColor = NSColor.labelColor.withAlphaComponent(0.8).cgColor

    if animate && pill.frame != pillFrame {
      NSAnimationContext.runAnimationGroup { context in
        context.duration = glassAnimationDuration
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

  func apply(_ snapshot: Snapshot) {
    let previous = self.snapshot
    self.snapshot = snapshot
    panel.appearance = snapshot.appearance == .dark ? NSAppearance(named: .darkAqua) : nil
    below = snapshot.hasCard
    let frame = below ? snapshot.card : snapshot.frame
    let primaryHeight = CGDisplayBounds(CGMainDisplayID()).height
    let cocoaFrame = NSRect(
      x: frame.minX, y: primaryHeight - frame.minY - frame.height, width: frame.width,
      height: frame.height)

    let visible = panel.isVisible
    let resized = panel.frame.size != cocoaFrame.size

    NSAnimationContext.beginGrouping()
    NSAnimationContext.current.duration = 0
    panel.setFrame(cocoaFrame, display: false)
    let animate =
      visible && !resized && previous?.entries.map(\.windowID) == snapshot.entries.map(\.windowID)
      && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    panel.effectiveAppearance.performAsCurrentDrawingAppearance {
      layout(snapshot, animate: animate)
    }
    NSAnimationContext.endGrouping()

    TabBarGlass.moveWindow(id, to: snapshot.sid)
    // NOTE: Keep AppKit's order in sync with SkyLight even for visible panels. Otherwise a newly created
    // outer card can be put back above an existing inner card when AppKit next displays its windows.
    panel.order(below ? .below : .above, relativeTo: Int(snapshot.aboveWid.rawValue))
    TabBarGlass.moveWindow(id, to: snapshot.sid)

    TabBarGlass.setLevel(of: id, snapshot.level, subLevel: snapshot.subLevel)
    TabBarGlass.orderPanel(id, below: below, relativeTo: snapshot.aboveWid)
    if below { EventLoop.post(.tabCardOrdered(windowID: snapshot.aboveWid)) }
  }

  func order(_ wid: WindowID) {
    guard panel.isVisible else { return }
    panel.order(below ? .below : .above, relativeTo: Int(wid.rawValue))
    if let snapshot { TabBarGlass.moveWindow(id, to: snapshot.sid) }
    TabBarGlass.orderPanel(id, below: below, relativeTo: wid)
    if below { EventLoop.post(.tabCardOrdered(windowID: wid)) }
  }
}

//
// NOTE: The object is created on the event loop thread, but AppKit only allows windows and views on the main thread.
// The panel is therefore created by the first update that reaches the main queue. Until then hide and order are no-ops,
// and the id of the panel is nil. The panel is @MainActor; the id is behind a Mutex, since the event loop reads it
// (TabBar.cardID) while the main queue sets it.
//

final class TabBarGlass: Sendable {
  private let panelId = Mutex<WindowID?>(nil)
  @MainActor private var panel: Panel?

  init() {}

  var id: WindowID? { panelId.withLock { $0 } }

  @MainActor
  fileprivate func apply(_ snapshot: Snapshot) {
    let panel = self.panel ?? Panel()
    if self.panel == nil {
      self.panel = panel
      panelId.withLock { $0 = WindowID(nonzero: panel.id.rawValue) }
    }
    panel.apply(snapshot)
  }

  @MainActor
  func hide() {
    panel?.pointer(windowID: nil, pressed: false)
    panel?.panel.orderOut(nil)
  }

  @MainActor
  func order(_ wid: WindowID) {
    panel?.order(wid)
  }

  @MainActor
  func close() {
    panel?.close()
    panel = nil
    panelId.withLock { $0 = nil }
  }

  func pointer(windowID: WindowID?, pressed: Bool) {
    onMain { $0.panel?.pointer(windowID: windowID, pressed: pressed) }
  }

  /// Takes a snapshot of the bar on the event loop and applies it on the main queue.
  @WM func render(
    _ bar: TabBar, above aboveWid: WindowID, entries: UnsafeMutablePointer<TabBarEntry>, count: Int
  ) {
    let snapshot = Snapshot(bar, aboveWid, entries, count)
    onMain { $0.apply(snapshot) }
  }

  func orderBar(above wid: WindowID) {
    onMain { $0.order(wid) }
  }

  func hideBar() {
    onMain { $0.hide() }
  }

  // NOTE: FIFO main-queue delivery closes the panel after pending updates; each block retains its owner.
  func destroyBar() {
    onMain { $0.close() }
  }

  static func innerRect(_ bounds: CGRect) -> CGRect {
    let inset = min(glassPillInset, max(0, min(bounds.width, bounds.height) * 0.5))
    return trackRect(bounds).insetBy(dx: inset, dy: inset)
  }

  //
  // NOTE: Glass is translucent, so a background color that was never configured is applied as a tint of the i3 color
  // with the given alpha instead of the opaque i3 color itself. A configured color is used exactly as given.
  //
  static func tint(_ color: RGBAColor, custom: Bool, alpha: Float) -> RGBAColor {
    var color = color
    if !custom { color.a = alpha }
    return color
  }

  static func moveWindow(_ wid: WindowID, to sid: SpaceID?) {
    SLS.moveWindows(SLS.connection, [wid], toSpace: sid)
  }

  static func setLevel(of wid: WindowID, _ level: Int32, subLevel: Int32) {
    SLS.setLevel(SLS.connection, wid, level)
    SLS.setSubLevel(SLS.connection, wid, subLevel)
  }

  //
  // NOTE: A card ordered below the window lands between the window and its border, so the border is ordered
  // right below the window again to stay on top of the card.
  //
  static func orderPanel(_ wid: WindowID, below: Bool, relativeTo relativeWid: WindowID) {
    SLS.order(SLS.connection, wid, below ? .below : .above, relativeTo: relativeWid)
    if below { Border.windowOrdered(relativeWid) }
  }

  fileprivate func onMain(_ body: @escaping @MainActor @Sendable (TabBarGlass) -> Void) {
    DispatchQueue.main.async {
      MainActor.assumeIsolated { body(self) }
    }
  }
}
