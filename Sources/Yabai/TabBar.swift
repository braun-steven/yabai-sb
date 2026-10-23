import Algorithms
import AppKit
import CPrivate
import CoreText
import OrderedCollections
import SortedCollections
import Synchronization
import YabaiCore

/// The classic bar window or native glass panel, and the tabs it shows.
@WM final class TabBar {
  /// The font of the tab bars until `config tab_bar_font` sets one.
  static let defaultFont = "system:12"

  /// The most tabs a tab bar shows.
  static let maxEntryCount = 64

  /// The drawing of the bar: nil until it is created, and again after `destroy()`.
  var backend: TabBarBackend?
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

/// How tab bars are drawn (`config tab_bar_style`).
enum TabBarStyle: String, CaseIterable, Sendable {
  case glass
  case i3
}

/// The card behind a glass tab bar (`config tab_bar_backdrop`).
enum TabBarBackdrop: String, CaseIterable, Sendable {
  case off
  case glass
  case blur
}

/// The colors of glass tab bars (`config tab_bar_appearance`).
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
  let style: TabBarStyle
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
  // NOTE: The rect the entries are laid out in (the backend's hitSlots), which may be inset from the frame.
  let slots: CGRect
  let sid: SpaceID
  let aboveWid: WindowID
  let entries: [WindowID?]
  // NOTE: The glass panel that takes the pointer feedback of this bar; nil for a classic bar.
  let pointer: TabBarGlass?
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
        let entries = Array(bar.entryWindowIDs.prefix(bar.entryCount))
        let slots = bar.backend?.hitSlots(bar.frame) ?? bar.frame
        hits.append(
          TabBarHit(
            frame: bar.frame, slots: slots, sid: sid, aboveWid: aboveWid, entries: entries,
            pointer: bar.backend?.glass))
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
  /// out in (`TabBarBackend.hitSlots`), inside `frame`.
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
  let target: TabBarGlass?
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
      hits.first { $0.pointer != nil && $0.frame.contains(point) && $0.sid.isVisible }
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

  private static func line(_ text: CFString, _ attributes: CFDictionary) -> CTLine {
    CTLineCreateWithAttributedString(CFAttributedStringCreate(nil, text, attributes)!)
  }

  //
  // NOTE: A title that is wider than maxWidth ends in an ellipsis.
  //
  static func fittedLine(_ title: CFString, attributes: CFDictionary, maxWidth: Double) -> CTLine {
    let full = line(title, attributes)
    if CTLineGetTypographicBounds(full, nil, nil, nil) <= maxWidth { return full }
    let token = line("…" as CFString, attributes)
    return CTLineCreateTruncatedLine(full, maxWidth, .end, token) ?? full
  }

  //
  // NOTE: Draws the application icon (if any) left of the title and centers both in the tab.
  // The title is truncated first; the icon is dropped only when the tab is too narrow for it.
  //
  static func drawTitle(
    in context: CGContext, font: CTFont?, glass: Bool, title: CFString?, icon: CGImage?,
    rect: CGRect, color: CGColor
  ) {
    let maxWidth = rect.width - 16
    if maxWidth <= 0 { return }
    let iconSpacing: CGFloat = glass ? 6 : 5
    let iconSize = CGFloat(
      Int(glass ? min(16, rect.height - 4) : rect.height * CGFloat(Float(0.7))))
    let icon = iconSize <= 0 || iconSize > maxWidth ? nil : icon
    let textMaxWidth = icon != nil ? maxWidth - iconSize - iconSpacing : maxWidth
    let title = font == nil || textMaxWidth <= 0 ? nil : title
    var line: CTLine?
    var ascent: CGFloat = 0
    var descent: CGFloat = 0
    var textWidth = 0.0
    if let title, let font {
      let attributes =
        [kCTFontAttributeName: font, kCTForegroundColorAttributeName: color] as CFDictionary
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
      let y =
        glass
        ? rect.minY + (rect.height - CTFontGetCapHeight(font)) * 0.5
        : rect.minY + (rect.height - (ascent + descent)) * 0.5 + descent
      context.textMatrix = .identity
      context.textPosition = CGPoint(x: Int(x), y: Int(y))
      CTLineDraw(line, context)
    }
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

  static func separatorColor(for text: RGBAColor) -> RGBAColor {
    var text = text
    text.a *= 0.25
    return text
  }

  static var cardPadding: Int {
    let config = Config.current.tabBar
    if config.style != .glass || config.backdrop == .off { return 0 }
    return config.cardPadding
  }

  private var exists: Bool { backend != nil }

  private func create(_ frame: CGRect) {
    WindowManager.shared.tabBars.append(self)
    // NOTE: A classic bar whose window the window server refuses has no backend, so it draws nothing (it is still in
    // tabBars and keeps its model, and the next render tries again).
    backend = TabBarBackend.make(frame: frame)
  }

  //
  // NOTE: Creates the backend if needed, moves the bar to the frame and to the space of the window it sits above, draws
  // the entries and orders it right above that window (right below it for a glass bar with a backdrop card, which
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
    if created { create(frame) }
    self.frame = frame
    // NOTE: The model moves to the space before the backend renders, so the backend sees the new space (sid), and
    // movedTo is set only when the space changed (the classic window is then moved there).
    var movedTo: SpaceID?
    if let space = aboveWid.space, space != sid {
      movedTo = space
      sid = space
    }
    aboveWindowID = aboveWid
    hidden = false
    self.entryCount = count
    entryWindowIDs = (0..<count).map { entries[$0].focusWindowID }

    let key = TabBarRenderKey(
      frame: frame, card: card, aboveWid: aboveWid, sid: sid, level: aboveWid.level,
      subLevel: aboveWid.subLevel, style: Config.current.tabBar.style,
      generation: ConfigObserver.shared.generation,
      mainDisplayHeight: CGDisplayBounds(CGMainDisplayID()).height,
      entries: (0..<count).map { i in
        TabBarRenderKey.Entry(
          focusWindowID: entries[i].focusWindowID, title: entries[i].title.map { $0 as String },
          icon: entries[i].icon, state: entries[i].state)
      })
    let draw = drawGate.needsDraw(key)
    if draw || created {
      backend?.render(
        self, frame: frame, movedTo: movedTo, above: aboveWid, entries: entries, count: count)
    } else {
      backend?.order(self, above: aboveWid)
    }
    TabBar.publishHits()
  }

  func hide() {
    if !exists || hidden { return }
    backend?.hide()
    hidden = true
    drawGate.reset()
    TabBar.publishHits()
  }

  func destroy() {
    if !exists { return }
    let wm = WindowManager.shared
    wm.tabBars.remove(self)
    backend?.destroy()
    reset()
    TabBar.publishHits()
  }

  /// Orders the bar right above its window (`wid`), or right below it for a glass bar with a card.
  func order(above wid: WindowID) {
    backend?.order(self, above: wid)
  }

  //
  // NOTE: Window id of the backdrop card of a visible bar, or nil when it has none (yet). The panel is created on the
  // main queue, so the id only becomes known after the first update of the bar reaches it.
  //
  var cardID: WindowID? {
    if hidden { return nil }
    let config = Config.current.tabBar
    if config.style != .glass || config.backdrop == .off { return nil }
    return backend?.cardID
  }

  static func orderBars(above wid: WindowID) {
    for bar in outerFirst(
      WindowManager.shared.tabBars.filter { !$0.hidden && $0.aboveWindowID == wid })
    {
      bar.order(above: wid)
    }
  }

  // NOTE: Ordering each card below the same window puts the last card in front. Creation order changes when
  // layouts or styles are rebuilt, so nested cards must explicitly be ordered from the outermost inward.
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

/// The SLS window of a classic (i3 style) tab bar: its shape, its space, its drawing and its order.
@WM final class ClassicTabBar {
  let id: WindowID
  var context: CGContext?
  // NOTE: The shape the window was last set to. Only a frame that changes is sent to SkyLight again.
  private var shape: CGRect

  //
  // NOTE: Created with SLSNewWindow instead of SLSNewWindowWithOpaqueShapeAndContext, because a window of the latter
  // is moved to the active space each time it is ordered in again, so a bar that was hidden and shown again would
  // land on whatever space is visible instead of the space of its window.
  //
  init?(frame: CGRect) {
    let region = SLS.region(frame)!
    guard let window = SLS.newWindow(SLS.connection, at: .zero, shape: region) else { return nil }
    id = window
    shape = frame
    SLS.setTags(SLS.connection, window, (1 << 1) | (1 << 9))
    SLS.disableShadow(window)
    SLS.setResolution(SLS.connection, window, 2)
    SLS.setOpaque(SLS.connection, window, false)
    context = SLS.context(SLS.connection, window)
  }

  /// Sets the shape to the frame when it changed, moves the window to `space` when the bar changed space, draws the
  /// entries and orders the window right above `aboveWid`. `sid` is the space of the bar after the move.
  func render(
    frame: CGRect, movedTo space: SpaceID?, sid: SpaceID?, above aboveWid: WindowID,
    entries: UnsafeMutablePointer<TabBarEntry>, count: Int
  ) {
    if frame != shape {
      let region = SLS.region(frame)!
      SLS.disableUpdate(SLS.connection)
      SLS.setShape(SLS.connection, id, region)
      SLS.reenableUpdate(SLS.connection)
      shape = frame
    }
    if let space { SLS.moveWindows(SLS.connection, [id], toSpace: space) }
    draw(entries, count: count, frame: frame)
    SLS.setLevel(SLS.connection, id, aboveWid.level)
    SLS.setSubLevel(SLS.connection, id, aboveWid.subLevel)
    SLS.order(SLS.connection, id, .above, relativeTo: aboveWid)
    keepOnSpace(sid)
  }

  func order(above wid: WindowID, sid: SpaceID?) {
    SLS.order(SLS.connection, id, .above, relativeTo: wid)
    keepOnSpace(sid)
  }

  func hide() {
    SLS.order(SLS.connection, id, .out)
  }

  func destroy() {
    SLS.order(SLS.connection, id, .out)
    context = nil
    SLS.releaseWindow(SLS.connection, id)
  }

  //
  // NOTE: Ordering a bar in can still move it to the active space, so its space is checked after every order and
  // fixed up when it no longer matches the space of the window it sits above.
  //
  private func keepOnSpace(_ sid: SpaceID?) {
    guard let sid, id.space != sid else { return }
    SLS.moveWindows(SLS.connection, [id], toSpace: sid)
  }

  private func draw(_ entries: UnsafeMutablePointer<TabBarEntry>, count: Int, frame: CGRect) {
    SLS.disableUpdate(SLS.connection)
    defer { SLS.reenableUpdate(SLS.connection) }
    guard let context else { return }
    let config = Config.current.tabBar
    let font = WindowManager.shared.tabBarFont
    let bounds = CGRect(origin: .zero, size: frame.size)
    context.clear(bounds)
    for i in 0..<count {
      let entry = entries[i]
      let (background, text) = entry.state.colors(in: config)
      let tab = TabBar.slot(in: bounds, index: i, count: count)
      ClassicTabBar.fill(context, background, tab)
      if i > 0 {
        ClassicTabBar.fill(
          context, TabBar.separatorColor(for: text),
          CGRect(x: tab.minX, y: 0, width: 1, height: bounds.height))
      }
      if entry.title != nil || entry.icon != nil {
        TabBar.drawTitle(
          in: context, font: font, glass: false, title: entry.title, icon: entry.icon, rect: tab,
          color: text.cgColor)
      }
    }
    context.flush()
  }

  // NOTE: Sets the fill with the components as given, which the classic bar has always drawn with.
  private static func fill(_ context: CGContext, _ color: RGBAColor, _ rect: CGRect) {
    context.setFillColor(
      red: CGFloat(color.r), green: CGFloat(color.g), blue: CGFloat(color.b),
      alpha: CGFloat(color.a))
    context.fill(rect)
  }
}

/// The drawing backend of a tab bar: the SLS window of a classic bar, or the AppKit panel of a glass bar. TabBar keeps
/// the model and calls one operation here; each operation is a single switch over the two cases.
@WM enum TabBarBackend {
  /// The kinds of backend, chosen by the style alone.
  enum Kind: Sendable {
    case classic
    case glass
  }

  case classic(ClassicTabBar)
  case glass(TabBarGlass)

  /// The backend a bar of the style is drawn with.
  static func kind(for style: TabBarStyle) -> Kind {
    switch style {
    case .glass: return .glass
    case .i3: return .classic
    }
  }

  /// The backend of a new bar, or nil when the window server refuses the window of a classic bar.
  static func make(frame: CGRect) -> TabBarBackend? {
    switch kind(for: Config.current.tabBar.style) {
    case .classic: return ClassicTabBar(frame: frame).map { TabBarBackend.classic($0) }
    case .glass: return .glass(TabBarGlass())
    }
  }

  /// Draws the bar; `movedTo` is the space the bar moved to in this render, nil when it stayed. The bar's model already
  /// has the new frame and space.
  func render(
    _ bar: TabBar, frame: CGRect, movedTo space: SpaceID?, above aboveWid: WindowID,
    entries: UnsafeMutablePointer<TabBarEntry>, count: Int
  ) {
    switch self {
    case .classic(let classic):
      classic.render(
        frame: frame, movedTo: space, sid: bar.sid, above: aboveWid, entries: entries, count: count)
    case .glass(let glass):
      glass.render(bar, above: aboveWid, entries: entries, count: count)
    }
  }

  func order(_ bar: TabBar, above wid: WindowID) {
    switch self {
    case .classic(let classic): classic.order(above: wid, sid: bar.sid)
    case .glass(let glass): glass.orderBar(above: wid)
    }
  }

  func hide() {
    switch self {
    case .classic(let classic): classic.hide()
    case .glass(let glass): glass.hideBar()
    }
  }

  func destroy() {
    switch self {
    case .classic(let classic): classic.destroy()
    case .glass(let glass): glass.destroyBar()
    }
  }

  /// The rect the entries are laid out in, inside the frame of the bar.
  func hitSlots(_ frame: CGRect) -> CGRect {
    switch self {
    case .classic: return frame
    case .glass: return TabBarGlass.innerRect(frame)
    }
  }

  /// The glass panel that takes the pointer feedback; nil for a classic bar.
  var glass: TabBarGlass? {
    switch self {
    case .classic: return nil
    case .glass(let glass): return glass
    }
  }

  /// The window of the backdrop card; a classic bar has none.
  var cardID: WindowID? {
    switch self {
    case .classic: return nil
    case .glass(let glass): return glass.id
    }
  }
}
