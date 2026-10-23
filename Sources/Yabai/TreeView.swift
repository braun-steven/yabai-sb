import CPrivate
import CoreGraphics
import Foundation
import YabaiCore

//
// NOTE: A view applies its container tree to the screen: window frames, tab bars, tab stacking, selected-container
// outlines and tree JSON. A view using the tree layout owns its root container in `tree`.
//

extension Con {
  /// The name of the application of the window of a leaf, nil when it has none.
  fileprivate var applicationName: String? {
    guard let windowID, let target = WindowManager.shared.window(for: windowID),
      let application = target.application
    else { return nil }
    return application.name
  }
}

//
// NOTE: The tab title of a container: the window title for a window, or the layout and the
// applications inside for a container, like i3 shows it (H[iTerm2 Safari]). TreeTitle builds the string.
//

extension Con {
  var title: CFString? {
    if isLeaf { return TabBar.title(for: windowID) }

    let string = TreeTitle.title(
      of: self,
      container: { $0.isLeaf ? nil : (layout: $0.layout, children: $0.children) },
      leafName: { $0.applicationName })
    return string as CFString
  }

  func destroyFeedback() {
    guard let feedbackWindowID = render.feedbackWindow.id else { return }

    SLS.order(SLS.connection, feedbackWindowID, .out)
    render.feedbackWindow.context = nil
    SLS.releaseWindow(SLS.connection, feedbackWindowID)
    render.feedbackWindow = FeedbackWindow()
  }
}

@WM private func treeBarHeight() -> Int {
  return TabBar.isEnabled ? Config.current.tabBar.height : 0
}

@WM private func treeBarInset() -> Int {
  return TabBar.isEnabled ? TabBar.cardPadding : 0
}

extension View {
  private var defaultLayout: ConLayout {
    switch Config.current.space.treeDefaultOrientation {
    case .horizontal: .splitH
    case .vertical: .splitV
    case .auto: area.w >= area.h ? .splitH : .splitV
    }
  }

  var root: Con {
    if tree == nil {
      tree = Con(layout: defaultLayout)
      tree!.area = area
    }

    return tree!
  }

  func updateTree() {
    guard let root = tree else { return }
    let config = Config.current.tabBar
    root.layOut(
      area, gap: windowGapValue, barHeight: treeBarHeight(), barOffset: config.offset,
      barInset: treeBarInset())
  }

  private func unmanageWindows(in node: Con) {
    if node.isLeaf {
      if let windowID = node.windowID { WindowManager.shared.removeManagedWindow(windowID) }
      return
    }

    for child in node.children { unmanageWindows(in: child) }
  }

  func clearTree() {
    // NOTE: The split drag layout of the space goes with its tree, so the event tap sees no gap of a removed tree.
    SplitDragCache.store(nil, for: sid)
    guard let root = tree else { return }

    unmanageWindows(in: root)
    root.destroy()
    tree = nil
    history.clear()
  }

  func findWindow(_ windowID: WindowID) -> Con? {
    guard let root = tree else { return nil }
    return root.find(windowID)
  }
}

//
// NOTE: A new window becomes the focused child of its containers unless the focused window is already on this space.
// A window moved here or made tiled stays behind the focused window so it is not hidden in another tab.
//

//
// NOTE: A new window opens next to the focused window, or next to
// the selected container (focus parent). An insertion point set with 'window --insert' or by a
// mouse drop places it on that side of its window instead, and the insertion point passed in is
// used for windows that are restored or moved here, so they open next to that window.
//

extension View {
  private func focusNewWindow(_ node: Con, windowID: WindowID) {
    node.focus()

    let focusedWindowID = WindowManager.shared.focus.focused
    if windowID != focusedWindowID, let focused = root.find(focusedWindowID) {
      focused.focus()
    }
  }

  private func resetEmptyRoot(_ root: Con) {
    if root.children.count != 0 { return }

    root.layout = defaultLayout
    root.lastSplit = root.layout
  }

  //
  // NOTE: insert= of the rule that matched a new window acts like window --insert on the focused window of this view,
  // the one its tree focuses, right before the window is added. The window takes it here, so it applies to its first
  // add only, and the add below consumes the insertion that it sets. Nothing is set when the view has no window.
  //

  private func insertByRule(_ direction: InsertDirection) {
    let focused = root.focusedDescendant
    guard focused.windowID != nil, focused.insertDirection != direction else { return }

    WindowManager.shared.setInsertion(of: focused, in: self, direction)
  }

  func add(_ target: Window, insertionPoint: WindowID?) {
    let root = self.root
    if root.find(target.id) != nil { return }

    if let direction = target.insertionByRule {
      target.insertionByRule = nil
      insertByRule(direction)
    }

    let node = Con(windowID: target.id)

    resetEmptyRoot(root)

    if let ownerInsertionPoint = self.insertionPoint, let anchor = root.find(ownerInsertionPoint),
      let direction = anchor.insertDirection
    {
      anchor.insertDirection = nil
      anchor.destroyFeedback()
      self.insertionPoint = nil

      anchor.insert(node, toward: direction)
      focusNewWindow(node, windowID: target.id)
    } else {
      var anchor = root.find(insertionPoint)

      if anchor == nil, let selected = root.findSelected(), !selected.isLeaf {
        anchor = selected
      }

      if anchor == nil { anchor = root.find(WindowManager.shared.focus.focused) }
      if anchor == nil { anchor = root.focusedDescendant }

      root.open(node, after: anchor, autotile: Config.current.space.treeAutotiling)
      focusNewWindow(node, windowID: target.id)
    }

    if !updateAutoPadding() { updateTree() }
    isDirty = true
  }

  //
  // NOTE: A container that moves here from another display, with its windows already moved to the
  // space of this view. It keeps its structure and arrives on the side it comes from.
  //

  func attach(_ node: Con, from direction: Direction) {
    let root = self.root
    resetEmptyRoot(root)
    root.attach(node, from: direction)
  }

  @discardableResult
  func remove(_ target: Window) -> Bool {
    guard let node = tree?.find(target.id) else { return false }

    if insertionPoint == target.id { insertionPoint = nil }

    node.detach()
    node.destroy()
    tree!.flatten()

    if !updateAutoPadding() { updateTree() }
    isDirty = true
    return true
  }

  private func appendWindowIDs(in node: Con, to result: inout [WindowID]) {
    if node.isLeaf {
      if let windowID = node.windowID { result.append(windowID) }
      return
    }

    for child in node.children { appendWindowIDs(in: child, to: &result) }
  }

  var windowIDs: [WindowID] {
    var result: [WindowID] = []
    if let tree { appendWindowIDs(in: tree, to: &result) }
    return result
  }

  //
  // NOTE: Counts the areas auto_padding cares about. A tabbed container shows one tab at a time,
  // so it is a single area no matter how many tabs it holds.
  //

  private func tiledCount(in node: Con) -> Int {
    if node.isLeaf { return node.zoom == .fullscreen ? 0 : 1 }

    var count = 0
    for child in node.children { count += tiledCount(in: child) }

    return node.layout == .tabbed && count > 1 ? 1 : count
  }

  var tiledCount: Int { tree.map { tiledCount(in: $0) } ?? 0 }
}

// NOTE: Border suppression counts the windows actually shown by the active tabs. Auto-padding
// keeps counting a whole tabbed container as one area, even when its active tab contains a split.
extension Con {
  func visibleWindowCount() -> Int {
    if isLeaf { return zoom == .fullscreen ? 0 : 1 }
    if layout == .tabbed {
      return children.count == 0 ? 0 : focusOrder[0].visibleWindowCount()
    }
    var count = 0
    for child in children { count += child.visibleWindowCount() }
    return count
  }
}

extension View {
  func frame(for node: Con) -> Area {
    if node.zoom == .fullscreen { return tree!.area }
    if node.zoom == .parent, let parent = node.parent { return parent.area }
    return node.area
  }
}

private func axDiff(_ a: Float, _ b: CGFloat) -> Bool {
  return abs(CGFloat(a) - b) >= 1.5
}

extension View {
  func needsFlush(windowID: WindowID, frame: CGRect) -> Bool {
    guard let node = findWindow(windowID) else { return false }

    let area = self.frame(for: node)
    return axDiff(area.x, frame.origin.x) || axDiff(area.y, frame.origin.y)
      || axDiff(area.w, frame.size.width) || axDiff(area.h, frame.size.height)
  }

  private func captureWindows(in node: Con, into windowList: inout [WindowPlacement]) {
    if node.isLeaf {
      if let windowID = node.windowID, let target = WindowManager.shared.window(for: windowID) {
        let area = frame(for: node)
        windowList.append(
          WindowPlacement(window: target, x: area.x, y: area.y, w: area.w, h: area.h))
      }
      return
    }

    for child in node.children { captureWindows(in: child, into: &windowList) }
  }
}

extension Con {
  func hasZoom(_ zoom: ConZoom) -> Bool {
    if isLeaf { return zoom == .none ? self.zoom != .none : self.zoom == zoom }

    for child in children {
      if child.hasZoom(zoom) { return true }
    }

    return false
  }

  var root: Con {
    var node = self
    while let parent = node.parent { node = parent }
    return node
  }

  func contains(_ windowID: WindowID?) -> Bool {
    find(windowID) != nil
  }
}

//
// NOTE: A zoomed window covers the bars of the containers it belongs to, and a fullscreen
// window covers every bar on the space.
//

extension Con {
  fileprivate var isBarShown: Bool {
    TabBar.isEnabled && layout == .tabbed && children.count > 0
      && area.h > Float(2 * Config.current.tabBar.height) && isVisible && !hasZoom(.none)
      && !root.hasZoom(.fullscreen)
  }
}

extension Con {
  func renderBar() {
    if !isBarShown {
      render.tabBar.hide()
      return
    }

    let config = Config.current.tabBar
    let entryCount = min(children.count, TabBar.maxEntryCount)
    let hasFocus = contains(WindowManager.shared.focus.focused)
    let active = focusOrder[0]

    var entryList: [TabBarEntry] = []

    for i in 0..<entryCount {
      let next = children[i]
      let leaf = next.focusedDescendant

      entryList.append(
        TabBarEntry(
          focusWindowID: leaf.windowID,
          title: next.title,
          icon: next.isLeaf ? TabBar.icon(for: next.windowID) : nil,
          state: next != active ? .unfocused : hasFocus ? .focused : .inactive))
    }

    render.tabBar.owner = self

    let above = focusedDescendant
    let area = self.area
    let inset = Float(
      TreeLayout.cardInset(area, barHeight: config.height, barInset: treeBarInset()))
    let card = CGRect(
      x: CGFloat(area.x), y: CGFloat(area.y), width: CGFloat(area.w), height: CGFloat(area.h))
    let frame = CGRect(
      x: CGFloat(area.x + inset), y: CGFloat(area.y + inset), width: CGFloat(area.w - 2 * inset),
      height: CGFloat(config.height))
    entryList.withUnsafeMutableBufferPointer { entries in
      render.tabBar.render(
        frame: frame, card: card, above: above.windowID, entries: entries.baseAddress!,
        count: entryCount)
    }
  }
}

//
// NOTE: The area a window border wraps. A window in a tabbed container is wrapped together with the bars of the
// containers it is the active tab of, i.e. the whole container, around its backdrop card when it has one (then
// radius is the corner radius of the card, otherwise 0 for the radius of the window). A window that is not in the
// tree gets empty areas, i.e. a border around the window itself. Returns false for a window of a hidden tab, which
// gets no border.
//

extension View {
  func borderArea(windowID: WindowID) -> (visible: Bool, window: Area, border: Area, radius: Int) {
    var windowArea = Area.zero
    var borderArea = Area.zero
    var radius = 0

    guard tree != nil, let leaf = findWindow(windowID) else {
      return (true, windowArea, borderArea, radius)
    }
    if !leaf.isVisible { return (false, windowArea, borderArea, radius) }

    var outer: Con?
    var node = leaf
    while let parent = node.parent, parent.layout == .tabbed, parent.isBarShown {
      outer = parent
      node = parent
    }

    windowArea = leaf.area
    borderArea = outer?.area ?? leaf.area

    if let outer {
      let config = Config.current.tabBar
      let inset = TreeLayout.cardInset(
        outer.area, barHeight: config.height, barInset: treeBarInset())
      if inset > 0 { radius = config.windowRadius + inset }
    }

    return (true, windowArea, borderArea, radius)
  }
}

extension Con {
  func renderBars() {
    if isLeaf { return }

    if layout == .tabbed {
      renderBar()
    } else {
      render.tabBar.destroy()
    }

    for child in children { child.renderBars() }
  }

  func releaseBars() {
    render.tabBar.destroy()

    for child in children { child.releaseBars() }
  }
}

extension Con {
  func collectWindowOrder(order: Int32, relative: WindowID, into list: inout [WindowOrder]) {
    if isLeaf {
      if let windowID = self.windowID, windowID != relative {
        list.append(WindowOrder(window: windowID, order: order, relativeTo: relative))
      }
      return
    }

    if order == 1 && layout == .tabbed {
      if !children.isEmpty {
        focusOrder[0].collectWindowOrder(order: order, relative: relative, into: &list)
      }
      return
    }

    for child in children {
      child.collectWindowOrder(order: order, relative: relative, into: &list)
    }
  }

  //
  // NOTE: Windows of hidden tabs keep the frame of their tabbed container and are hidden by
  // stacking order alone. When a tab becomes active, the windows of the other tabs are ordered
  // below the backdrop card of the container (below its focused window without a card), and
  // the other visible windows of the tab (when it holds a split) are ordered above it. The card
  // itself sits right below the focused window, so this is redone when either of them changes.
  // The focused window is also ordered right above the card: the card does not reliably follow
  // its own ordering, and a new window was ordered below the card as a hidden tab before it got
  // focus, which the application then does not raise again. The orderings of the whole tree are
  // collected first and sent to the scripting addition in one message.
  //

  func collectTabOrder(force: Bool, into list: inout [WindowOrder]) {
    if isLeaf { return }

    if layout == .tabbed && !children.isEmpty && isVisible {
      let active = focusOrder[0]

      let anchor = active.focusedDescendant
      let anchorWid = anchor.windowID
      let cardWid = render.tabBar.cardID

      if force || render.raised != active || render.raisedAnchor != anchorWid
        || render.raisedCard != cardWid
      {
        render.raised = active
        render.raisedAnchor = anchorWid
        render.raisedCard = cardWid

        if let anchorWid, let cardWid {
          list.append(WindowOrder(window: anchorWid, order: 1, relativeTo: cardWid))
        }

        // NOTE: The other tabs are ordered against the card, or the anchor when there is no card. Without either
        // there is no window to order them against.
        if children.count > 1, let relative = cardWid ?? anchorWid {
          for next in children where next != active {
            next.collectWindowOrder(order: -1, relative: relative, into: &list)
          }
        }

        if !active.isLeaf, let anchorWid {
          active.collectWindowOrder(order: 1, relative: anchorWid, into: &list)
        }
      }
    }

    for child in children { child.collectTabOrder(force: force, into: &list) }
  }

  func raiseTabs(force: Bool) {
    var list: [WindowOrder] = []
    collectTabOrder(force: force, into: &list)

    if !list.isEmpty { ScriptingAddition.shared.orderWindows(list) }
  }

  //
  // NOTE: The card is ordered right below the focused window of the active tab on the main queue. The application
  // raises a window above the other windows of a split tab whenever it gets
  // focus, so a card ordered after that (by any redraw of the bar, e.g. on a title change or when another
  // application gets focus) lands between them and hides the other windows. They are therefore ordered above
  // the focused window again each time the card has been ordered below it.
  //

  func collectCardOrder(after windowID: WindowID, into list: inout [WindowOrder]) {
    if isLeaf { return }

    if layout == .tabbed && !children.isEmpty && isVisible {
      let active = focusOrder[0]
      if !active.isLeaf && active.focusedDescendant.windowID == windowID {
        active.collectWindowOrder(order: 1, relative: windowID, into: &list)
        return
      }
    }

    for child in children { child.collectCardOrder(after: windowID, into: &list) }
  }
}

extension WindowManager {
  func cardDidOrder(_ windowID: WindowID) {
    guard let owner = managedWindows[windowID] else { return }
    if owner.layout != .tree || owner.tree == nil || !owner.sid.isVisible { return }

    var list: [WindowOrder] = []
    owner.tree!.collectCardOrder(after: windowID, into: &list)
    if !list.isEmpty { ScriptingAddition.shared.orderWindows(list) }
  }
}

extension View {
  func flushTree(animated: Bool = true) {
    guard let root = tree else { return }

    var windowList: [WindowPlacement] = []
    captureWindows(in: root, into: &windowList)
    if !windowList.isEmpty { WindowManager.shared.animateWindows(windowList, animated: animated) }

    root.renderBars()
    root.raiseTabs(force: false)

    if let selected = root.findSelected() { selected.showSelection() }

    if let insertionPoint, let insert = root.find(insertionPoint),
      let insertDir = insert.insertDirection
    {
      insert.showFeedback(direction: insertDir)
    }

    // NOTE: Explicit, after the frames and tabs of the flush, so the borders match the new layout in this event.
    Border.refresh(space: sid)
  }

  /// The flush of headless mode: applies the frames of the tree, without tab bars, feedback windows or borders.
  func flushHeadless() {
    isDirty = false
    guard let root = tree else { return }

    var windowList: [WindowPlacement] = []
    captureWindows(in: root, into: &windowList)
    Headless.apply(windowList)
  }

  func focusWindow(_ windowID: WindowID) {
    guard let node = findWindow(windowID) else { return }

    tree?.select(nil)
    node.focus()

    if !sid.isVisible {
      isDirty = true
      return
    }

    tree!.raiseTabs(force: false)
    tree!.renderBars()
  }
}

extension View {
  static func refreshBars(forWindowID windowID: WindowID?) {
    guard let windowID, let owner = WindowManager.shared.managedWindows[windowID] else { return }
    if owner.layout != .tree || owner.tree == nil { return }

    if owner.sid.isVisible { owner.tree!.renderBars() }
  }
}

//
// NOTE: Outline of a container, drawn with the insert feedback color. Without a direction
// it outlines the whole container, which marks the container selected with 'window --focus parent'.
// With a direction it shows the half where a window will be inserted, as set by 'window --insert'
// or while dragging a window with the mouse.
//

// INSERT_FEEDBACK_WIDTH, INSERT_FEEDBACK_RADIUS
private let insertFeedbackWidth: CGFloat = 2
private let insertFeedbackRadius: Float = 9

//
// NOTE: What an outline shows. A container draws its outline again only when this changes; the outline is ordered on
// every call. The color is part of the key because insert_feedback_color is not a config group that is observed. A ghost
// is keyed by the window it is an image of, not by the image: a drag captures one image per window.
//
struct FeedbackKey: Equatable {
  let area: Area
  let direction: InsertDirection?
  let color: RGBAColor
  let ghost: WindowID?
}

extension Con {
  /// Orders the outline of the container. With a ghost (`mouse_drop_preview ghost`), the outline shows the image of that
  /// window, scaled into the half or the whole area of the direction at half alpha, and has no fill.
  func showFeedback(
    direction insertDir: InsertDirection?, ghost: (window: WindowID, image: CGImage)? = nil
  ) {
    guard let windowID = focusedDescendant.windowID else { return }

    let cid = SLS.connection
    let area = self.area

    if render.feedbackWindow.id == nil {
      let frameRegion = SLS.region(
        CGRect(
          x: CGFloat(area.x), y: CGFloat(area.y), width: CGFloat(area.w), height: CGFloat(area.h)))!
      render.feedbackWindow.id = SLS.newWindow(
        cid, shape: frameRegion, options: 13, tags: (1 << 1) | (1 << 9))

      if let feedbackID = render.feedbackWindow.id {
        SLS.disableShadow(feedbackID)
        SLS.setResolution(cid, feedbackID, 1.0)
        SLS.setOpaque(cid, feedbackID, false)
        let context = SLS.context(cid, feedbackID)
        render.feedbackWindow.context = context
        context?.setLineWidth(insertFeedbackWidth)
      }
    }

    // NOTE: A window server that did not create the outline leaves no window to draw into or order.
    guard let feedbackWindowID = render.feedbackWindow.id else { return }

    let color = Config.current.window.insertionFeedbackColor
    let draw = render.feedbackWindow.gate.needsDraw(
      FeedbackKey(area: area, direction: insertDir, color: color, ghost: ghost?.window))
    if draw {
      drawFeedback(
        outline: feedbackWindowID, area: area, direction: insertDir, color: color,
        ghost: ghost?.image)
    }

    SLS.setLevel(cid, feedbackWindowID, windowID.level)
    SLS.setSubLevel(cid, feedbackWindowID, windowID.subLevel)
    SLS.order(cid, feedbackWindowID, .above, relativeTo: windowID)
  }

  /// Draws the outline of the area into its window, the fill and stroke clipped to the half that `insertDir` marks. With a
  /// ghost image, the image takes the place of the fill: it is drawn at half alpha into the same half, and the stroke follows.
  private func drawFeedback(
    outline feedbackWindowID: WindowID, area: Area, direction insertDir: InsertDirection?,
    color: RGBAColor, ghost: CGImage?
  ) {
    let cid = SLS.connection
    let frame = CGRect(x: 0, y: 0, width: CGFloat(area.w), height: CGFloat(area.h))
    let frameRegion = SLS.region(
      CGRect(
        x: CGFloat(area.x), y: CGFloat(area.y), width: CGFloat(area.w), height: CGFloat(area.h)))!

    // NOTE: Drawing calls have no effect without a context.
    let context = render.feedbackWindow.context
    context?.setFillColor(
      red: CGFloat(color.r), green: CGFloat(color.g), blue: CGFloat(color.b),
      alpha: CGFloat(color.a * (insertDir != nil ? 0.25 : 0.15)))
    context?.setStrokeColor(
      red: CGFloat(color.r), green: CGFloat(color.g), blue: CGFloat(color.b),
      alpha: CGFloat(color.a))

    var clipX = -0.5 * insertFeedbackWidth
    var clipY = -0.5 * insertFeedbackWidth
    var clipW = insertFeedbackWidth
    var clipH = insertFeedbackWidth
    let midx = frame.midX
    let midy = frame.midY

    switch insertDir {
    case .north: clipY = midy - 0.5 * insertFeedbackWidth
    case .east: clipX = midx - 0.5 * insertFeedbackWidth
    case .south: clipH = -midy + insertFeedbackWidth
    case .west: clipW = -midx + insertFeedbackWidth
    default: break
    }

    let rect = CGRect(
      x: 0.5 * insertFeedbackWidth, y: 0.5 * insertFeedbackWidth,
      width: frame.size.width - insertFeedbackWidth, height: frame.size.height - insertFeedbackWidth
    )
    let fill = rect.insetBy(dx: 0.5 * insertFeedbackWidth, dy: 0.5 * insertFeedbackWidth)
    let clip = CGRect(
      x: rect.origin.x + clipX, y: rect.origin.y + clipY, width: rect.size.width + clipW,
      height: rect.size.height + clipH)
    let path = CGPath(
      roundedRect: rect, cornerWidth: CGFloat(rect.clampedXRadius(insertFeedbackRadius)),
      cornerHeight: CGFloat(rect.clampedYRadius(insertFeedbackRadius)), transform: nil)

    SLS.disableUpdate(cid)
    SLS.setShape(cid, feedbackWindowID, frameRegion)
    context?.clear(frame)
    context?.clip(to: clip)
    if let ghost {
      // NOTE: The ghost is drawn into the area the direction covers (DropPreview.covered), in the coordinates of the clip.
      let covered = DropPreview.covered(frame, by: insertDir)
      let size = CGSize(width: ghost.width, height: ghost.height)
      if let fit = DropPreview.fit(size, in: covered) {
        context?.saveGState()
        context?.setAlpha(0.5)
        context?.draw(ghost, in: fit)
        context?.restoreGState()
      }
    } else {
      context?.fill(fill)
    }
    context?.addPath(path)
    context?.strokePath()
    context?.resetClip()
    context?.flush()
    SLS.reenableUpdate(cid)
  }

  func hideFeedback() { destroyFeedback() }

  func showSelection() { showFeedback(direction: nil) }
}
