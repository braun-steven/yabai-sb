import Algorithms
import AppKit
import CPrivate
import CoreText
import OrderedCollections
import SortedCollections
import Synchronization
import YabaiCore

/// The tab bar of a container and the tabs it shows. The AppKit panel that draws it is at the bottom of this file.
@WM final class TabBar {
  /// The font of the tab bars until `config tab_bar_font` sets one.
  static let defaultFont = "system:12"

  /// The most tabs a tab bar shows.
  static let maxEntryCount = 64

  /// The drawing panel of the bar: nil until it is created, and again after `destroy()`.
  var backend: TabBarGlass?
  var frame = CGRect.zero
  var card = CGRect.zero
  var sid: SpaceID?
  var aboveWindowID: WindowID?
  var hidden = false
  var entryCount = 0
  var entryWindowIDs: [WindowID?] = []
  // NOTE: The container that embeds the bar. It redraws the bar when colors or fonts change.
  weak var owner: Con?
  // NOTE: The key of the last draw. Hiding or destroying the bar forgets it, so the bar is drawn when it is shown again.
  private var drawGate = RenderGate<TabBarRenderKey>()

  /// The empty bar of `destroy()`, which keeps its owner.
  func reset() {
    backend = nil
    frame = .zero
    card = .zero
    sid = nil
    aboveWindowID = nil
    hidden = false
    entryCount = 0
    entryWindowIDs = []
    drawGate.reset()
  }
}

extension TabBar: Hashable {
  nonisolated static func == (a: TabBar, b: TabBar) -> Bool { a === b }
  nonisolated func hash(into hasher: inout Hasher) { hasher.combine(ObjectIdentifier(self)) }
}

/// The card behind the tab bar (`config tab_bar_backdrop`).
enum TabBarBackdrop: String, CaseIterable, Sendable {
  case off
  case glass
  case blur
}

/// The appearance of the tab bar (`config tab_bar_appearance`).
enum TabBarAppearance: String, CaseIterable, Sendable {
  case dark
  case system
}

/// The state of a tab: the focused window's tab, the active tab of an unfocused container, or any other tab.
enum TabBarState: Sendable {
  case unfocused
  case inactive
  case focused
}

extension TabBarState {
  /// The background and text colors of a tab in this state.
  @WM func colors(in config: TabBarConfig) -> (background: RGBAColor, text: RGBAColor) {
    switch self {
    case .focused: return (config.focusedColor, config.focusedTextColor)
    case .inactive: return (config.inactiveColor, config.inactiveTextColor)
    case .unfocused: return (config.unfocusedColor, config.unfocusedTextColor)
    }
  }
}

extension RGBAColor {
  var cgColor: CGColor {
    CGColor(srgbRed: CGFloat(r), green: CGFloat(g), blue: CGFloat(b), alpha: CGFloat(a))
  }
}

struct TabBarEntry {
  var focusWindowID: WindowID?
  var title: CFString?
  var icon: CGImage?
  var state: TabBarState
}

//
// NOTE: What a tab bar draws, as its last draw saw it. A render with an equal key draws nothing new and only orders the
// bar again (TabBar.render). The icon is compared by identity: an application keeps the icon it loaded (TabBar.icon), so
// it changes only when a new icon is loaded. The config generation (ConfigObserver) covers every tab bar setting, and the
// main display height covers the frame that the glass panel converts with it.
//
struct TabBarRenderKey: Equatable {
  struct Entry: Equatable {
    let focusWindowID: WindowID?
    let title: String?
    let icon: CGImage?
    let state: TabBarState

    static func == (a: Entry, b: Entry) -> Bool {
      a.focusWindowID == b.focusWindowID && a.title == b.title && a.state == b.state
        && a.icon === b.icon
    }
  }

  let frame: CGRect
  let card: CGRect
  let aboveWid: WindowID
  let sid: SpaceID?
  let level: Int32
  let subLevel: Int32
  let generation: Int
  let mainDisplayHeight: CGFloat
  let entries: [Entry]
}

//
// NOTE: Snapshot of the visible tab layout, read by the mouse event tap to resolve clicks on a
// tab bar without touching the window tree from another thread.
//
private struct TabBarHit: Sendable {
  let frame: CGRect
  // NOTE: The rect the entries are laid out in (`TabBarGlass.innerRect`), which may be inset from the frame.
  let slots: CGRect
  let sid: SpaceID
  let aboveWid: WindowID
  let entries: [WindowID?]
  // NOTE: The panel that takes the pointer feedback of this bar.
  let pointer: TabBarGlass
}
private let tabBarHits = Mutex<[TabBarHit]>([])

extension TabBar {
  //
  // NOTE: The font is "<family>:<size>", split at the last ':'. The size is read with sscanf "%f", which skips leading
  // whitespace and ignores trailing text. The family "system" is the system UI font.
  //

  /// The tab at the index among count tabs of the area, rounded with float widths and integer offsets.
  nonisolated static func slot(in area: CGRect, index: Int, count: Int) -> CGRect {
    let width = Float(area.size.width / CGFloat(count))
    let x0 = Float(area.origin.x + CGFloat(Int(Float(index) * width)))
    let x1 =
      index == count - 1
      ? Float(area.origin.x + area.size.width)
      : Float(area.origin.x + CGFloat(Int(Float(index + 1) * width)))
    return CGRect(
      x: CGFloat(x0), y: area.origin.y, width: CGFloat(x1 - x0), height: area.size.height)
  }

  static func setFont(_ name: String) -> Bool {
    let utf8 = name.utf8
    guard let separator = utf8.lastIndex(of: UInt8(ascii: ":")), separator != utf8.startIndex else {
      return false
    }
    let scan = Token(utf8[utf8.index(after: separator)...]).scanFloats(count: 1)
    guard scan.assigned == 1, let size = scan.values.first, !(size <= 0) else { return false }
    let family = String(decoding: utf8[..<separator], as: UTF8.self)
    let font: CTFont? =
      family == "system"
      ? CTFontCreateUIFontForLanguage(.system, CGFloat(size), nil)
      : CTFontCreateWithName(family as CFString, CGFloat(size), nil)
    guard let font else { return false }
    let wm = WindowManager.shared
    wm.tabBarFont = font
    Config.current.tabBar.fontName = name
    return true
  }

  static var isEnabled: Bool {
    let config = Config.current.tabBar
    return config.enabled && config.height > 0
  }

  private static func publishHits() {
    tabBarHits.withLock { hits in
      hits.removeAll(keepingCapacity: true)
      for bar in WindowManager.shared.tabBars where hits.count < 256 {
        if bar.hidden || bar.entryCount == 0 { continue }
        // NOTE: A bar that shows entries has been rendered above a window on a space, so both are set.
        guard let sid = bar.sid, let aboveWid = bar.aboveWindowID else { continue }
        // NOTE: A bar that shows entries has a backend: render creates it before it sets the entries.
        guard let backend = bar.backend else { continue }
        let entries = Array(bar.entryWindowIDs.prefix(bar.entryCount))
        hits.append(
          TabBarHit(
            frame: bar.frame, slots: TabBarGlass.innerRect(bar.frame), sid: sid, aboveWid: aboveWid,
            entries: entries, pointer: backend))
      }
    }
  }

  //
  // NOTE: The bar only sits right above the window it belongs to, so windows ordered in front of that
  // window (menu bar extras, Control Center, notifications, floating windows) may cover it. A click goes
  // to the bar only when the window that would receive it is one of ours or is ordered behind the bar.
  //
  /// The window at the point when it could cover the bar: another application's, ordered over the bar's window.
  private nonisolated static func coveringWindow(
    at point: CGPoint, above aboveWid: WindowID
  ) -> WindowID? {
    let (found, owner) = SLS.findWindow(SLS.connection, at: point, startingAt: nil, order: 1)
    guard let wid = found, owner != SLS.connection, wid != aboveWid else { return nil }
    return wid
  }

  /// The windows ordered above the bar's window, front to back. Nil when the window server gives no list.
  private nonisolated static func windowsAbove(_ aboveWid: WindowID) -> Set<WindowID>? {
    guard let windows = CGWindowListCreateC(.optionOnScreenAboveWindow, aboveWid.rawValue) else {
      return nil
    }
    // NOTE: The list holds the window ids as raw pointer-sized values, not CFNumbers, so an id is the bit pattern.
    var ids = Set<WindowID>()
    for index in 0..<CFArrayGetCount(windows) {
      guard let value = CFArrayGetValueAtIndex(windows, index) else { continue }
      ids.insert(WindowID(UInt32(truncatingIfNeeded: UInt(bitPattern: value))))
    }
    return ids
  }

  /// Uncached, for clicks: a click must never go to a covered bar.
  private nonisolated static func isCovered(_ point: CGPoint, above aboveWid: WindowID) -> Bool {
    guard let wid = coveringWindow(at: point, above: aboveWid),
      let windows = windowsAbove(aboveWid)
    else { return false }
    return windows.contains(wid)
  }

  /// Bumped by the window server's order and destroy notifications (MissionControl.swift). Read by the event tap.
  nonisolated static func windowOrderChanged() {
    hoverGeneration.wrappingAdd(1, ordering: .relaxed)
  }

  nonisolated static func hitTest(_ point: CGPoint, window: inout WindowID?) -> Bool {
    let above: WindowID? = tabBarHits.withLock { hits in
      for hit in hits {
        if !hit.frame.contains(point) || !hit.sid.isVisible { continue }
        guard
          let index = hitIndex(point, frame: hit.frame, slots: hit.slots, count: hit.entries.count)
        else { continue }
        window = hit.entries[index]
        return hit.aboveWid
      }
      return nil
    }
    return above.map { !isCovered(point, above: $0) } ?? false
  }

  /// Match the drawn slots, including the rounded track's outer hit padding. `slots` is the rect the entries are laid
  /// out in (`TabBarGlass.innerRect`), inside `frame`.
  nonisolated static func hitIndex(_ point: CGPoint, frame: CGRect, slots: CGRect, count: Int)
    -> Int?
  {
    guard count > 0, frame.width > 0, frame.contains(point) else { return nil }
    // NOTE: The slots run from left to right, so the first slot ending right of the point is found by bisection.
    return (0..<count - 1).partitioningIndex {
      point.x < slot(in: slots, index: $0, count: count).maxX
    }
  }

}

/// The order generation of the windows (`TabBar.windowOrderChanged`). Relaxed: a stale read only costs one more check.
private let hoverGeneration = Atomic<UInt64>(0)

/// The glass entry under the pointer before the coverage check: what the hover would show if nothing covers it.
private struct TabBarPointerEntry {
  let target: TabBarGlass
  let windowID: WindowID?
  let aboveWid: WindowID
}

// NOTE: The event tap owns pointer state. It only sends changes to AppKit; it never reads the window tree. The
// fields after `pressed` remember the last call's input and its window server answers (HoverCoverageCache), so an
// identical call asks nothing, and a new point reuses the window list above the bar while it is fresh.
private struct TabBarPointer: Sendable {
  var target: TabBarGlass?
  var windowID: WindowID?
  var pressed = false
  var point: CGPoint?
  var candidate: TabBarGlass?
  var candidateWindowID: WindowID?
  var check: HoverCoverageStamp?
  var windows: Set<WindowID> = []
  var windowsStamp: HoverCoverageStamp?
}
private let tabBarPointer = Mutex(TabBarPointer())

extension TabBar {
  nonisolated static func updatePointer(_ point: CGPoint, pressed: Bool) {
    let hit = tabBarHits.withLock { hits in
      hits.first { $0.frame.contains(point) && $0.sid.isVisible }
    }
    // NOTE: The entry comes from the hit table alone. The window server is asked only when there is one.
    var entry: TabBarPointerEntry?
    if let hit,
      let index = hitIndex(point, frame: hit.frame, slots: hit.slots, count: hit.entries.count)
    {
      entry = TabBarPointerEntry(
        target: hit.pointer, windowID: hit.entries[index], aboveWid: hit.aboveWid)
    }
    let generation = hoverGeneration.load(ordering: .relaxed)
    let now = ContinuousClock.now
    let decision = tabBarPointer.withLock { state -> HoverCoverageCheck? in
      guard let entry else { return nil }
      let repeats =
        state.point == point && state.candidate === entry.target
        && state.candidateWindowID == entry.windowID && state.pressed == pressed
      return HoverCoverageCache.decide(
        repeatsLastCheck: repeats, lastCheck: state.check, list: state.windowsStamp,
        aboveWid: entry.aboveWid, generation: generation, now: now)
    }
    // NOTE: A skip repeats the last call, whose result is already in the state; nothing to send.
    if decision == .skip { return }

    var covered = false
    var listed: (windows: Set<WindowID>, stamp: HoverCoverageStamp)?
    if let entry, let decision, let wid = coveringWindow(at: point, above: entry.aboveWid) {
      if decision == .checkWithCachedList {
        covered = tabBarPointer.withLock { $0.windows.contains(wid) }
      } else if let windows = windowsAbove(entry.aboveWid) {
        covered = windows.contains(wid)
        listed = (
          windows, HoverCoverageStamp(aboveWid: entry.aboveWid, generation: generation, taken: now)
        )
      }
    }
    let target = covered ? nil : entry?.target
    let windowID = covered ? nil : entry?.windowID

    let change = tabBarPointer.withLock { state -> (Bool, TabBarGlass?) in
      let previous = state.target
      state.point = point
      state.candidate = entry?.target
      state.candidateWindowID = entry?.windowID
      if let entry {
        state.check = HoverCoverageStamp(
          aboveWid: entry.aboveWid, generation: generation, taken: now)
      }
      if let listed {
        state.windows = listed.windows
        state.windowsStamp = listed.stamp
      }
      let changed =
        state.target !== target || state.windowID != windowID || state.pressed != pressed
      state.target = target
      state.windowID = windowID
      state.pressed = pressed
      return (changed, previous)
    }
    guard change.0 else { return }
    if change.1 !== target { change.1?.pointer(windowID: nil, pressed: false) }
    target?.pointer(windowID: windowID, pressed: pressed)
  }

  static func title(for wid: WindowID?) -> CFString? {
    guard let wid, let target = WindowManager.shared.window(for: wid) else { return nil }
    if let title = target.ax.title, !title.isEmpty { return title as CFString }
    if let app = target.application { return app.name as CFString }
    return nil
  }

  //
  // NOTE: The application icon of a window, loaded once per application and owned by it.
  //
  static func icon(for wid: WindowID?) -> CGImage? {
    guard Config.current.tabBar.icons, let wid,
      let target = WindowManager.shared.window(for: wid), let app = target.application
    else { return nil }
    if let icon = app.icon { return icon }
    autoreleasepool {
      if let image = NSRunningApplication(processIdentifier: app.pid)?.icon {
        var rect = CGRect(x: 0, y: 0, width: 64, height: 64)
        if let icon = image.cgImage(forProposedRect: &rect, context: nil, hints: nil) {
          app.icon = icon
        }
      }
    }
    return app.icon
  }

  static var cardPadding: Int {
    let config = Config.current.tabBar
    if config.backdrop == .off { return 0 }
    return config.cardPadding
  }

  private var exists: Bool { backend != nil }

  private func create() {
    WindowManager.shared.tabBars.append(self)
    backend = TabBarGlass()
  }

  //
  // NOTE: Creates the backend if needed, moves the bar to the frame and to the space of the window it sits above, draws
  // the entries and orders it right above that window (right below it for a bar with a backdrop card, which
  // then covers the whole card). Titles stay owned by the caller. A render whose key equals the last draw keeps the
  // drawing and only orders the bar again: the ordering is always done, since other windows may have moved.
  //
  func render(
    frame: CGRect, card: CGRect, above aboveWid: WindowID?,
    entries: UnsafeMutablePointer<TabBarEntry>, count entryCount: Int
  ) {
    self.card = card
    // NOTE: A bar without a window to sit above has nothing to be ordered against; it is hidden.
    guard let aboveWid else {
      hide()
      return
    }
    let count = min(entryCount, TabBar.maxEntryCount)
    let created = !exists
    if created { create() }
    self.frame = frame
    // NOTE: The model moves to the space before the panel snapshots it.
    if let space = aboveWid.space, space != sid {
      sid = space
    }
    aboveWindowID = aboveWid
    hidden = false
    self.entryCount = count
    entryWindowIDs = (0..<count).map { entries[$0].focusWindowID }

    let key = TabBarRenderKey(
      frame: frame, card: card, aboveWid: aboveWid, sid: sid, level: aboveWid.level,
      subLevel: aboveWid.subLevel, generation: ConfigObserver.shared.generation,
      mainDisplayHeight: CGDisplayBounds(CGMainDisplayID()).height,
      entries: (0..<count).map { i in
        TabBarRenderKey.Entry(
          focusWindowID: entries[i].focusWindowID, title: entries[i].title.map { $0 as String },
          icon: entries[i].icon, state: entries[i].state)
      })
    let draw = drawGate.needsDraw(key)
    if draw || created {
      backend?.render(self, above: aboveWid, entries: entries, count: count)
    } else {
      backend?.orderBar(above: aboveWid)
    }
    TabBar.publishHits()
  }

  func hide() {
    if !exists || hidden { return }
    backend?.hideBar()
    hidden = true
    drawGate.reset()
    TabBar.publishHits()
  }

  func destroy() {
    if !exists { return }
    let wm = WindowManager.shared
    wm.tabBars.remove(self)
    backend?.destroyBar()
    reset()
    TabBar.publishHits()
  }

  /// Orders the bar right above its window (`wid`), or right below it for a bar with a card.
  func order(above wid: WindowID) {
    backend?.orderBar(above: wid)
  }

  //
  // NOTE: Window id of the backdrop card of a visible bar, or nil when it has none (yet). The panel is created on the
  // main queue, so the id only becomes known after the first update of the bar reaches it.
  //
  var cardID: WindowID? {
    if hidden { return nil }
    let config = Config.current.tabBar
    if config.backdrop == .off { return nil }
    return backend?.id
  }

  static func orderBars(above wid: WindowID) {
    for bar in outerFirst(
      WindowManager.shared.tabBars.filter { !$0.hidden && $0.aboveWindowID == wid })
    {
      bar.order(above: wid)
    }
  }

  // NOTE: Ordering each card below the same window puts the last card in front. Creation order changes when
  // layouts are rebuilt, so nested cards must explicitly be ordered from the outermost inward.
  static func outerFirst(_ bars: some Sequence<TabBar>) -> [TabBar] {
    bars.sorted { $0.card.width * $0.card.height > $1.card.width * $1.card.height }
  }

  static func redrawAll() {
    for bar in outerFirst(WindowManager.shared.tabBars) { bar.owner?.renderBar() }
  }

  //
  // NOTE: Called explicitly after a focus change rather than through Observation: the bars are laid out with the
  // tree (View.refreshBars), and the tab card must be ordered right after the tabs are raised (tabCardOrdered).
  //
  static func refresh(for wid: WindowID?) {
    guard let wid, let owner = WindowManager.shared.managedWindows[wid] else { return }
    if owner.layout != .tree { return }
    View.refreshBars(forWindowID: wid)
  }

  //
  // NOTE: Called after a tab bar config change that affects the layout (TabBarConfig.needsRebuild). Drops every bar so
  // that the next layout pass recreates them with the new settings, then re-lays out all views to apply the new window
  // area.
  //
  static func refreshAll() {
    for owner in SpaceManager.shared.views.values where owner.layout == .tree {
      owner.tree?.releaseBars()
      owner.updateAndFlush()
    }
    publishHits()
  }

  /// Applies a set of the tab bar config. A change of the drawing only redraws the bars; other sets, also of an equal
  /// value, rebuild them as their setters did.
  static func applyConfig(_ config: TabBarConfig, from old: TabBarConfig) {
    if config != old && !config.needsRebuild(from: old) { redrawAll() } else { refreshAll() }
  }
}

//
// NOTE: The AppKit side of the tab bar. AppKit must be used from the main thread, so the event loop hands a
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
  // NOTE: Glass is translucent, so a background color that was never configured is applied as a tint of that color
  // with the given alpha instead of the opaque color itself. A configured color is used exactly as given.
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
