import CoreGraphics
import Foundation
import CPrivate
import YabaiCore

//
// NOTE: A view applies its container tree to the screen: window frames, tab bars, tab stacking, selected-container
// outlines and tree JSON. A view using the tree layout owns its root container in `tree`.
//

extension Con
{
    private func appendTitle(to string: CFMutableString)
    {
        if isLeaf {
            if let windowID, let target = WindowManager.shared.window(for: windowID),
               let application = target.application {
                CFStringAppend(string, application.name as CFString)
            }
            return
        }

        CFStringAppendCString(string, layout == .splitH ? "H[" : layout == .splitV ? "V[" : "T[", CFStringBuiltInEncodings.UTF8.rawValue)

        for i in 0..<children.count {
            if i > 0 { CFStringAppendCString(string, " ", CFStringBuiltInEncodings.UTF8.rawValue) }
            children[i].appendTitle(to: string)
        }

        CFStringAppendCString(string, "]", CFStringBuiltInEncodings.UTF8.rawValue)
    }
}

//
// NOTE: The tab title of a container: the window title for a window, or the layout and the
// applications inside for a container, like i3 shows it (H[iTerm2 Safari]).
//

extension Con
{
    var title: CFString?
    {
        if isLeaf { return tab_bar_copy_title(windowID) }

        let string = CFStringCreateMutable(nil, 0)!
        appendTitle(to: string)
        return string
    }

    func destroyFeedback()
    {
        guard let feedbackWindowID = render.feedbackWindow.id else { return }

        SLSOrderWindow(SLS.connection, feedbackWindowID.rawValue, 0, 0)
        render.feedbackWindow.context = nil
        SLSReleaseWindow(SLS.connection, feedbackWindowID.rawValue)
        render.feedbackWindow = FeedbackWindow()
    }
}

private func treeBarHeight() -> Int
{
    return tab_bar_is_enabled() ? WindowManager.shared.tabBarHeight : 0
}

private func treeBarInset() -> Int
{
    return tab_bar_is_enabled() ? tab_bar_card_padding() : 0
}

extension View
{
    private var defaultLayout: ConLayout
    {
        switch SpaceManager.shared.treeDefaultOrientation {
        case .horizontal: .splitH
        case .vertical:   .splitV
        case .auto:       area.w >= area.h ? .splitH : .splitV
        }
    }

    var root: Con
    {
        if tree == nil {
            tree = Con(layout: defaultLayout)
            tree!.area = area
        }

        return tree!
    }

    func updateTree()
    {
        guard let root = tree else { return }
        root.layOut(area, gap: windowGapValue, barHeight: treeBarHeight(), barOffset: WindowManager.shared.tabBarOffset, barInset: treeBarInset())
    }

    private func unmanageWindows(in node: Con)
    {
        if node.isLeaf {
            if let windowID = node.windowID { WindowManager.shared.removeManagedWindow(windowID) }
            return
        }

        for child in node.children { unmanageWindows(in: child) }
    }

    func clearTree()
    {
        guard let root = tree else { return }

        unmanageWindows(in: root)
        root.destroy()
        tree = nil
    }

    func findWindow(_ windowID: WindowID) -> Con?
    {
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

extension View
{
    private func focusNewWindow(_ node: Con, windowID: WindowID)
    {
        node.focus()

        let focusedWindowID = WindowManager.shared.focusedWindowID
        if windowID != focusedWindowID, let focused = root.find(focusedWindowID) {
            focused.focus()
        }
    }

    private func resetEmptyRoot(_ root: Con)
    {
        if root.children.count != 0 { return }

        root.layout = defaultLayout
        root.lastSplit = root.layout
    }

    func add(_ target: Window, insertionPoint: WindowID?)
    {
        let root = self.root
        if root.find(target.id) != nil { return }

        let node = Con(windowID: target.id)

        resetEmptyRoot(root)

        if let ownerInsertionPoint = self.insertionPoint, let anchor = root.find(ownerInsertionPoint), let direction = anchor.insertDirection {
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

            if anchor == nil { anchor = root.find(WindowManager.shared.focusedWindowID) }
            if anchor == nil { anchor = root.focusedDescendant }

            root.open(node, after: anchor, autotile: SpaceManager.shared.treeAutotiling)
            focusNewWindow(node, windowID: target.id)
        }

        if !updateAutoPadding() { updateTree() }
        isDirty = true
    }

//
// NOTE: A container that moves here from another display, with its windows already moved to the
// space of this view. It keeps its structure and arrives on the side it comes from.
//

    func attach(_ node: Con, from direction: Direction)
    {
        let root = self.root
        resetEmptyRoot(root)
        root.attach(node, from: direction)
    }

    @discardableResult
    func remove(_ target: Window) -> Bool
    {
        guard let node = tree?.find(target.id) else { return false }

        if insertionPoint == target.id { insertionPoint = nil }

        node.detach()
        node.destroy()
        tree!.flatten()

        if !updateAutoPadding() { updateTree() }
        isDirty = true
        return true
    }

    private func appendWindowIDs(in node: Con, to result: inout [WindowID])
    {
        if node.isLeaf {
            if let windowID = node.windowID { result.append(windowID) }
            return
        }

        for child in node.children { appendWindowIDs(in: child, to: &result) }
    }

    var windowIDs: [WindowID]
    {
        var result: [WindowID] = []
        if let tree { appendWindowIDs(in: tree, to: &result) }
        return result
    }

//
// NOTE: Counts the areas auto_padding cares about. A tabbed container shows one tab at a time,
// so it is a single area no matter how many tabs it holds.
//

    private func tiledCount(in node: Con) -> Int
    {
        if node.isLeaf { return node.zoom == .fullscreen ? 0 : 1 }

        var count = 0
        for child in node.children { count += tiledCount(in: child) }

        return node.layout == .tabbed && count > 1 ? 1 : count
    }

    var tiledCount: Int { tree.map { tiledCount(in: $0) } ?? 0 }
}

// NOTE: Border suppression counts the windows actually shown by the active tabs. Auto-padding
// keeps counting a whole tabbed container as one area, even when its active tab contains a split.
extension Con
{
    func visibleWindowCount() -> Int
    {
        if isLeaf { return zoom == .fullscreen ? 0 : 1 }
        if layout == .tabbed {
            return children.count == 0 ? 0 : focusOrder[0].visibleWindowCount()
        }
        var count = 0
        for child in children { count += child.visibleWindowCount() }
        return count
    }
}

extension View
{
    func frame(for node: Con) -> Area
    {
        if node.zoom == .fullscreen { return tree!.area }
        if node.zoom == .parent, let parent = node.parent { return parent.area }
        return node.area
    }
}

private func axDiff(_ a: Float, _ b: CGFloat) -> Bool
{
    return abs(CGFloat(a) - b) >= 1.5
}

extension View
{
    func needsFlush(windowID: WindowID, frame: CGRect) -> Bool
    {
        guard let node = findWindow(windowID) else { return false }

        let area = self.frame(for: node)
        return axDiff(area.x, frame.origin.x) ||
               axDiff(area.y, frame.origin.y) ||
               axDiff(area.w, frame.size.width) ||
               axDiff(area.h, frame.size.height)
    }

    private func captureWindows(in node: Con, into windowList: inout [window_capture])
    {
        if node.isLeaf {
            if let windowID = node.windowID, let target = WindowManager.shared.window(for: windowID) {
                let area = frame(for: node)
                windowList.append(window_capture(window: target, x: area.x, y: area.y, w: area.w, h: area.h))
            }
            return
        }

        for child in node.children { captureWindows(in: child, into: &windowList) }
    }
}

extension Con
{
    func hasZoom(_ zoom: ConZoom) -> Bool
    {
        if isLeaf { return zoom == .none ? self.zoom != .none : self.zoom == zoom }

        for child in children {
            if child.hasZoom(zoom) { return true }
        }

        return false
    }

    var root: Con
    {
        var node = self
        while let parent = node.parent { node = parent }
        return node
    }

    func contains(_ windowID: WindowID?) -> Bool
    {
        find(windowID) != nil
    }
}

//
// NOTE: A zoomed window covers the bars of the containers it belongs to, and a fullscreen
// window covers every bar on the space.
//

extension Con
{
    fileprivate var isBarShown: Bool
    {
        tab_bar_is_enabled() &&
        layout == .tabbed &&
        children.count > 0 &&
        area.h > Float(2 * WindowManager.shared.tabBarHeight) &&
        isVisible &&
        !hasZoom(.none) &&
        !root.hasZoom(.fullscreen)
    }
}

private func redrawTabBar(_ owner: UnsafeMutableRawPointer?)
{
    Unmanaged<Con>.fromOpaque(owner!).takeUnretainedValue().renderBar()
}

extension Con
{
    fileprivate func renderBar()
    {
        if !isBarShown {
            tab_bar_hide(render.tabBar)
            return
        }

        let wm = WindowManager.shared
        let entryCount = min(children.count, tabBarMaxEntryCount)
        let hasFocus = contains(wm.focusedWindowID)
        let active = focusOrder[0]

        var entryList: [TabBarEntry] = []

        for i in 0..<entryCount {
            let next = children[i]
            let leaf = next.focusedDescendant

            entryList.append(TabBarEntry(
                focus_wid: leaf.windowID,
                title: next.title,
                icon: next.isLeaf ? tab_bar_icon(next.windowID) : nil,
                state: next != active ? .unfocused : hasFocus ? .focused : .inactive))
        }

        render.tabBar.owner = Unmanaged.passUnretained(self).toOpaque()
        render.tabBar.redraw = redrawTabBar

        let above = focusedDescendant
        let area = self.area
        let inset = Float(Con.cardInset(area, barHeight: wm.tabBarHeight, barInset: treeBarInset()))
        let card = CGRect(x: CGFloat(area.x), y: CGFloat(area.y), width: CGFloat(area.w), height: CGFloat(area.h))
        let frame = CGRect(x: CGFloat(area.x + inset), y: CGFloat(area.y + inset), width: CGFloat(area.w - 2 * inset), height: CGFloat(wm.tabBarHeight))
        entryList.withUnsafeMutableBufferPointer { entries in
            tab_bar_render(render.tabBar, frame, card, above.windowID, entries.baseAddress!, entryCount)
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

extension View
{
    func borderArea(windowID: WindowID) -> (visible: Bool, window: Area, border: Area, radius: Int)
    {
        var windowArea = Area.zero
        var borderArea = Area.zero
        var radius = 0

        guard tree != nil, let leaf = findWindow(windowID) else { return (true, windowArea, borderArea, radius) }
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
            let wm = WindowManager.shared
            let inset = Con.cardInset(outer.area, barHeight: wm.tabBarHeight, barInset: treeBarInset())
            if inset > 0 { radius = wm.tabBarWindowRadius + inset }
        }

        return (true, windowArea, borderArea, radius)
    }
}

extension Con
{
    func renderBars()
    {
        if isLeaf { return }

        if layout == .tabbed {
            renderBar()
        } else {
            tab_bar_release(render.tabBar)
        }

        for child in children { child.renderBars() }
    }

    func releaseBars()
    {
        tab_bar_release(render.tabBar)

        for child in children { child.releaseBars() }
    }
}

extension Con
{
    func collectWindowOrder(order: Int32, relative: WindowID, into list: inout [sa_window_order])
    {
        if isLeaf {
            if let windowID = self.windowID, windowID != relative { list.append(sa_window_order(a_wid: windowID, order: order, b_wid: relative)) }
            return
        }

        if order == 1 && layout == .tabbed {
            if !children.isEmpty { focusOrder[0].collectWindowOrder(order: order, relative: relative, into: &list) }
            return
        }

        for child in children { child.collectWindowOrder(order: order, relative: relative, into: &list) }
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

    func collectTabOrder(force: Bool, into list: inout [sa_window_order])
    {
        if isLeaf { return }

        if layout == .tabbed && !children.isEmpty && isVisible {
            let active = focusOrder[0]

            let anchor = active.focusedDescendant
            let anchorWid = anchor.windowID
            let cardWid = tab_bar_card_id(render.tabBar)

            if force || render.raised != active || render.raisedAnchor != anchorWid || render.raisedCard != cardWid {
                render.raised = active
                render.raisedAnchor = anchorWid
                render.raisedCard = cardWid

                if let anchorWid, let cardWid {
                    list.append(sa_window_order(a_wid: anchorWid, order: 1, b_wid: cardWid))
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

    func raiseTabs(force: Bool)
    {
        var list: [sa_window_order] = []
        collectTabOrder(force: force, into: &list)

        if !list.isEmpty { scripting_addition_order_window_list(list) }
    }

//
// NOTE: The card is ordered right below the focused window of the active tab on the main queue. The application
// raises a window above the other windows of a split tab whenever it gets
// focus, so a card ordered after that (by any redraw of the bar, e.g. on a title change or when another
// application gets focus) lands between them and hides the other windows. They are therefore ordered above
// the focused window again each time the card has been ordered below it.
//

    func collectCardOrder(after windowID: WindowID, into list: inout [sa_window_order])
    {
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

extension WindowManager
{
    func cardDidOrder(_ windowID: WindowID)
    {
        guard let owner = managedWindows[windowID] else { return }
        if owner.layout != .tree || owner.tree == nil || !owner.sid.isVisible { return }

        var list: [sa_window_order] = []
        owner.tree!.collectCardOrder(after: windowID, into: &list)
        if !list.isEmpty { scripting_addition_order_window_list(list) }
    }
}

extension View
{
    func flushTree()
    {
        guard let root = tree else { return }

        var windowList: [window_capture] = []
        captureWindows(in: root, into: &windowList)
        if !windowList.isEmpty { window_manager_animate_window_list(windowList) }

        root.renderBars()
        root.raiseTabs(force: false)

        if let selected = root.findSelected() { selected.showSelection() }

        if let insertionPoint, let insert = root.find(insertionPoint), let insertDir = insert.insertDirection {
            insert.showFeedback(direction: insertDir)
        }

        border_refresh_space(sid)
    }

    func focusWindow(_ windowID: WindowID)
    {
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

extension View
{
    static func refreshBars(forWindowID windowID: WindowID?)
    {
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

extension Con
{
    func showFeedback(direction insertDir: InsertDirection?)
    {
        guard let windowID = focusedDescendant.windowID else { return }

        let cid = SLS.connection
        let area = self.area
        var frame = CGRect(x: CGFloat(area.x), y: CGFloat(area.y), width: CGFloat(area.w), height: CGFloat(area.h))
        var region: CFTypeRef?
        CGSNewRegionWithRect(&frame, &region)
        let frameRegion = region!
        frame.origin.x = 0; frame.origin.y = 0

        if render.feedbackWindow.id == nil {
            var tags: UInt64 = (1 << 1) | (1 << 9)
            let emptyRegion = CGRegionCreateEmptyRegion()
            var feedbackID: UInt32 = 0
            SLSNewWindowWithOpaqueShapeAndContext(cid, 2, frameRegion, emptyRegion, 13, &tags, 0, 0, 64, &feedbackID, nil)
            render.feedbackWindow.id = WindowID(nonzero: feedbackID)

            sls_window_disable_shadow(feedbackID)
            SLSSetWindowResolution(cid, feedbackID, 1.0)
            SLSSetWindowOpacity(cid, feedbackID, false)
            let context = SLWindowContextCreate(cid, feedbackID, nil)
            render.feedbackWindow.context = context
            context?.setLineWidth(insertFeedbackWidth)
        }

        // NOTE: A window server that did not create the outline leaves no window to draw into or order.
        guard let feedbackWindowID = render.feedbackWindow.id else { return }

        // NOTE: Drawing calls have no effect without a context.
        let context = render.feedbackWindow.context
        let color = WindowManager.shared.insertionFeedbackColor
        context?.setFillColor(red: CGFloat(color.r), green: CGFloat(color.g), blue: CGFloat(color.b), alpha: CGFloat(color.a * (insertDir != nil ? 0.25 : 0.15)))
        context?.setStrokeColor(red: CGFloat(color.r), green: CGFloat(color.g), blue: CGFloat(color.b), alpha: CGFloat(color.a))

        var clipX = -0.5 * insertFeedbackWidth
        var clipY = -0.5 * insertFeedbackWidth
        var clipW = insertFeedbackWidth
        var clipH = insertFeedbackWidth
        let midx = frame.midX
        let midy = frame.midY

        switch insertDir {
        case .north: clipY = midy - 0.5 * insertFeedbackWidth
        case .east:  clipX = midx - 0.5 * insertFeedbackWidth
        case .south: clipH = -midy + insertFeedbackWidth
        case .west:  clipW = -midx + insertFeedbackWidth
        default:        break
        }

        let rect = CGRect(x: 0.5 * insertFeedbackWidth, y: 0.5 * insertFeedbackWidth, width: frame.size.width - insertFeedbackWidth, height: frame.size.height - insertFeedbackWidth)
        let fill = rect.insetBy(dx: 0.5 * insertFeedbackWidth, dy: 0.5 * insertFeedbackWidth)
        let clip = CGRect(x: rect.origin.x + clipX, y: rect.origin.y + clipY, width: rect.size.width + clipW, height: rect.size.height + clipH)
        let path = CGPath(roundedRect: rect, cornerWidth: CGFloat(cgrect_clamp_x_radius(rect, insertFeedbackRadius)), cornerHeight: CGFloat(cgrect_clamp_y_radius(rect, insertFeedbackRadius)), transform: nil)

        SLSDisableUpdate(cid)
        SLSSetWindowShape(cid, feedbackWindowID.rawValue, 0.0, 0.0, frameRegion)
        context?.clear(frame)
        context?.clip(to: clip)
        context?.fill(fill)
        context?.addPath(path)
        context?.strokePath()
        context?.resetClip()
        context?.flush()
        SLSReenableUpdate(cid)

        SLSSetWindowLevel(cid, feedbackWindowID.rawValue, windowID.level)
        SLSSetWindowSubLevel(cid, feedbackWindowID.rawValue, windowID.subLevel)
        SLSOrderWindow(cid, feedbackWindowID.rawValue, 1, windowID.rawValue)
    }

    func hideFeedback() { destroyFeedback() }

    func showSelection() { showFeedback(direction: nil) }
}
