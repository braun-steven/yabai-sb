import CoreGraphics
import Foundation
import CPrivate
import YabaiCore

//
// NOTE: Applies the container trees of Tree.swift to the screen: the tree of a view, window frames,
// tab bars, the stacking order of tabs, the outline of selected containers and the JSON of a tree.
// A view that uses the 'tree' layout owns its root container in view->tree. Ported from src/tree_view.c.
//

/// `tree_append_title`
private func treeAppendTitle(_ string: CFMutableString, _ node: Con)
{
    if con_is_leaf(node) {
        if let windowID = node.window_id, let target = window_manager_find_window(window_manager_global(), windowID),
           let application = target.application {
            CFStringAppend(string, application.name as CFString)
        }
        return
    }

    let layout = node.layout
    CFStringAppendCString(string, layout == .splitH ? "H[" : layout == .splitV ? "V[" : "T[", CFStringBuiltInEncodings.UTF8.rawValue)

    for i in 0..<node.child_count {
        if i > 0 { CFStringAppendCString(string, " ", CFStringBuiltInEncodings.UTF8.rawValue) }
        treeAppendTitle(string, node.children[i])
    }

    CFStringAppendCString(string, "]", CFStringBuiltInEncodings.UTF8.rawValue)
}

//
// NOTE: The tab title of a container: the window title for a window, or the layout and the
// applications inside for a container, like i3 shows it (H[iTerm2 Safari]).
//

/// `tree_copy_title`
func tree_copy_title(_ node: Con) -> CFString?
{
    if con_is_leaf(node) { return tab_bar_copy_title(node.window_id) }

    let string = CFStringCreateMutable(nil, 0)!
    treeAppendTitle(string, node)
    return string
}

/// `tree_feedback_destroy`
func treeFeedbackDestroy(_ node: Con)
{
    guard let feedbackWindowID = node.render.feedback_window.id else { return }

    SLSOrderWindow(connection_global(), feedbackWindowID.rawValue, 0, 0)
    node.render.feedback_window.context = nil
    SLSReleaseWindow(connection_global(), feedbackWindowID.rawValue)
    node.render.feedback_window = FeedbackWindow()
}

/// `tree_bar_height`
private func treeBarHeight() -> Int
{
    return tab_bar_is_enabled() ? window_manager_global().tab_bar_height : 0
}

/// `tree_bar_inset`
private func treeBarInset() -> Int
{
    return tab_bar_is_enabled() ? tab_bar_card_padding() : 0
}

/// `tree_default_layout`
private func treeDefaultLayout(_ owner: View) -> ConLayout
{
    switch space_manager_global().tree_default_orientation {
    case .horizontal: .splitH
    case .vertical:   .splitV
    case .auto:       owner.area.w >= owner.area.h ? .splitH : .splitV
    }
}

/// `tree_view_root`
func tree_view_root(_ owner: View) -> Con
{
    if owner.tree == nil {
        owner.tree = con_create(treeDefaultLayout(owner))
        owner.tree.area = owner.area
    }

    return owner.tree
}

/// `tree_view_update`
func tree_view_update(_ owner: View!)
{
    guard let root = owner.tree else { return }
    tree_update(root, owner.area, view_window_gap(owner), treeBarHeight(), window_manager_global().tab_bar_offset, treeBarInset())
}

/// `tree_unmanage_windows`
private func treeUnmanageWindows(_ node: Con)
{
    if con_is_leaf(node) {
        if let windowID = node.window_id { window_manager_remove_managed_window(window_manager_global(), windowID) }
        return
    }

    for i in 0..<node.child_count {
        treeUnmanageWindows(node.children[i])
    }
}

/// `tree_view_clear`
func tree_view_clear(_ owner: View)
{
    guard let root = owner.tree else { return }

    treeUnmanageWindows(root)
    con_free(root)
    owner.tree = nil
}

/// `tree_view_find_window`
func tree_view_find_window(_ owner: View!, _ windowID: WindowID) -> Con!
{
    guard let root = owner.tree else { return nil }
    return tree_find_window(root, windowID)
}

//
// NOTE: A new window becomes the focused child of its containers, as i3 focuses new windows, unless
// the focused window is on this space: a window that is moved here or stops floating then stays
// behind it, so that the focused window is not hidden in another tab.
//

/// `tree_focus_new_window`
private func treeFocusNewWindow(_ root: Con, _ node: Con, _ windowID: WindowID)
{
    tree_focus(node)

    let focusedWindowID = window_manager_global().focused_window_id
    if windowID != focusedWindowID, let focused = tree_find_window(root, focusedWindowID) {
        tree_focus(focused)
    }
}

/// `tree_view_reset_empty_root`
private func treeViewResetEmptyRoot(_ owner: View, _ root: Con)
{
    if root.child_count != 0 { return }

    root.layout = treeDefaultLayout(owner)
    root.last_split = root.layout
}

//
// NOTE: A new window opens where tree_open_con puts it: next to the focused window, or next to
// the selected container (focus parent). An insertion point set with 'window --insert' or by a
// mouse drop places it on that side of its window instead, and the insertion point passed in is
// used for windows that are restored or moved here, so they open next to that window.
//

/// `tree_add_window`
func tree_add_window(_ owner: View, _ target: Window, _ insertionPoint: WindowID?)
{
    let root = tree_view_root(owner)
    if tree_find_window(root, target.id) != nil { return }

    let node = con_create(.splitH)!
    node.window_id = target.id

    treeViewResetEmptyRoot(owner, root)

    if let ownerInsertionPoint = owner.insertion_point, let anchor = tree_find_window(root, ownerInsertionPoint), let direction = anchor.insert_dir {
        anchor.insert_dir = nil
        treeFeedbackDestroy(anchor)
        owner.insertion_point = nil

        tree_insert_relative(anchor, node, direction)
        treeFocusNewWindow(root, node, target.id)
        return
    }

    var anchor: Con? = tree_find_window(root, insertionPoint)

    if anchor == nil, let selected = tree_find_selected(root), !con_is_leaf(selected) {
        anchor = selected
    }

    if anchor == nil { anchor = tree_find_window(root, window_manager_global().focused_window_id) }
    if anchor == nil { anchor = tree_descend_focused(root) }

    tree_open_con(root, node, anchor, space_manager_global().tree_autotiling)
    treeFocusNewWindow(root, node, target.id)
}

//
// NOTE: A container that moves here from another display, with its windows already moved to the
// space of this view. It keeps its structure and arrives on the side it comes from.
//

/// `tree_view_attach_from_direction`
func tree_view_attach_from_direction(_ owner: View, _ node: Con, _ direction: Direction)
{
    let root = tree_view_root(owner)
    treeViewResetEmptyRoot(owner, root)
    tree_attach_from_direction(root, node, direction)
}

/// `tree_remove_window`
func tree_remove_window(_ owner: View, _ target: Window) -> Bool
{
    guard let node = tree_find_window(owner.tree, target.id) else { return false }

    if owner.insertion_point == target.id { owner.insertion_point = nil }

    tree_detach(node)
    con_free(node)
    tree_flatten(owner.tree)

    return true
}

/// `tree_append_window_list`
private func treeAppendWindowList(_ node: Con, _ windowList: inout [WindowID])
{
    if con_is_leaf(node) {
        if let windowID = node.window_id { windowList.append(windowID) }
        return
    }

    for i in 0..<node.child_count {
        treeAppendWindowList(node.children[i], &windowList)
    }
}

/// `tree_view_window_list`: the windows of the tree in its order.
func treeViewWindowList(_ owner: View) -> [WindowID]
{
    var windowList: [WindowID] = []
    if let root = owner.tree { treeAppendWindowList(root, &windowList) }
    return windowList
}

//
// NOTE: Counts the areas auto_padding cares about. A tabbed container shows one tab at a time,
// so it is a single area no matter how many tabs it holds.
//

/// `tree_tiled_count`
private func treeTiledCount(_ node: Con) -> Int
{
    if con_is_leaf(node) { return node.zoom == .fullscreen ? 0 : 1 }

    var count = 0
    for i in 0..<node.child_count {
        count += treeTiledCount(node.children[i])
    }

    return node.layout == .tabbed && count > 1 ? 1 : count
}

/// `tree_view_tiled_count`
func tree_view_tiled_count(_ owner: View!) -> Int
{
    guard let root = owner.tree else { return 0 }
    return treeTiledCount(root)
}

// NOTE: Border suppression counts the windows actually shown by the active tabs. Auto-padding
// keeps counting a whole tabbed container as one area, even when its active tab contains a split.
func treeVisibleWindowCount(_ node: Con) -> Int
{
    if con_is_leaf(node) { return node.zoom == .fullscreen ? 0 : 1 }
    if node.layout == .tabbed {
        return node.child_count == 0 ? 0 : treeVisibleWindowCount(node.focus[0])
    }
    var count = 0
    for child in node.children { count += treeVisibleWindowCount(child) }
    return count
}

/// `tree_con_frame`
func tree_con_frame(_ owner: View, _ node: Con) -> Area
{
    if node.zoom == .fullscreen { return owner.tree.area }
    if node.zoom == .parent, let parent = node.parent { return parent.area }
    return node.area
}

/// `AX_DIFF` (view.h)
private func axDiff(_ a: Float, _ b: CGFloat) -> Bool
{
    return abs(CGFloat(a) - b) >= 1.5
}

/// `tree_window_needs_flush`
func tree_window_needs_flush(_ owner: View, _ windowID: WindowID, _ frame: CGRect) -> Bool
{
    guard let node = tree_view_find_window(owner, windowID) else { return false }

    let area = tree_con_frame(owner, node)
    return axDiff(area.x, frame.origin.x) ||
           axDiff(area.y, frame.origin.y) ||
           axDiff(area.w, frame.size.width) ||
           axDiff(area.h, frame.size.height)
}

/// `tree_capture_windows`
private func treeCaptureWindows(_ owner: View, _ node: Con, _ windowList: inout [window_capture])
{
    if con_is_leaf(node) {
        if let windowID = node.window_id, let target = window_manager_find_window(window_manager_global(), windowID) {
            let area = tree_con_frame(owner, node)
            windowList.append(window_capture(window: target, x: area.x, y: area.y, w: area.w, h: area.h))
        }
        return
    }

    for i in 0..<node.child_count {
        treeCaptureWindows(owner, node.children[i], &windowList)
    }
}

/// `tree_has_zoom`
func treeHasZoom(_ node: Con, _ zoom: ConZoom) -> Bool
{
    if con_is_leaf(node) { return zoom == .none ? node.zoom != .none : node.zoom == zoom }

    for i in 0..<node.child_count {
        if treeHasZoom(node.children[i], zoom) { return true }
    }

    return false
}

/// `tree_root_of`
private func treeRootOf(_ node: Con) -> Con
{
    var node = node
    while let parent = node.parent { node = parent }
    return node
}

/// `tree_contains_window`
func treeContainsWindow(_ node: Con, _ windowID: WindowID?) -> Bool
{
    return tree_find_window(node, windowID) != nil
}

//
// NOTE: A zoomed window covers the bars of the containers it belongs to, and a fullscreen
// window covers every bar on the space.
//

/// `tree_bar_is_shown`
private func treeBarIsShown(_ node: Con) -> Bool
{
    return tab_bar_is_enabled() &&
           node.layout == .tabbed &&
           node.child_count > 0 &&
           node.area.h > Float(2 * window_manager_global().tab_bar_height) &&
           tree_con_is_visible(node) &&
           !treeHasZoom(node, .none) &&
           !treeHasZoom(treeRootOf(node), .fullscreen)
}

//
// NOTE: The redraw callback of the tab bar of a container (TabBar.swift calls it with the container as
// the owner, unretained); the container outlives its bar, which con_free releases.
//

private func treeRenderBarCallback(_ owner: UnsafeMutableRawPointer?)
{
    treeRenderBar(Unmanaged<Con>.fromOpaque(owner!).takeUnretainedValue())
}

/// `tree_render_bar`
private func treeRenderBar(_ node: Con)
{
    if !treeBarIsShown(node) {
        tab_bar_hide(node.render.tab_bar)
        return
    }

    let wm = window_manager_global()
    let entryCount = min(node.child_count, tabBarMaxEntryCount)
    let hasFocus = treeContainsWindow(node, wm.focused_window_id)
    let active = node.focus[0]

    var entryList: [TabBarEntry] = []

    for i in 0..<entryCount {
        let next = node.children[i]
        let leaf = tree_descend_focused(next)

        entryList.append(TabBarEntry(
            focus_wid: leaf?.window_id,
            title: tree_copy_title(next),
            icon: con_is_leaf(next) ? tab_bar_icon(next.window_id) : nil,
            state: next != active ? .unfocused : hasFocus ? .focused : .inactive))
    }

    node.render.tab_bar.owner = Unmanaged.passUnretained(node).toOpaque()
    node.render.tab_bar.redraw = treeRenderBarCallback

    let above = tree_descend_focused(node)
    let area = node.area
    let inset = Float(tree_bar_card_inset(area, wm.tab_bar_height, treeBarInset()))
    let card = CGRect(x: CGFloat(area.x), y: CGFloat(area.y), width: CGFloat(area.w), height: CGFloat(area.h))
    let frame = CGRect(x: CGFloat(area.x + inset), y: CGFloat(area.y + inset), width: CGFloat(area.w - 2 * inset), height: CGFloat(wm.tab_bar_height))
    entryList.withUnsafeMutableBufferPointer { entries in
        tab_bar_render(node.render.tab_bar, frame, card, above?.window_id, entries.baseAddress!, entryCount)
    }
}

//
// NOTE: The area a window border wraps. A window in a tabbed container is wrapped together with the bars of the
// containers it is the active tab of, i.e. the whole container, around its backdrop card when it has one (then
// radius is the corner radius of the card, otherwise 0 for the radius of the window). A window that is not in the
// tree gets empty areas, i.e. a border around the window itself. Returns false for a window of a hidden tab, which
// gets no border.
//

/// `tree_window_border_area`
func tree_window_border_area(_ owner: View!, _ windowID: WindowID, _ windowArea: inout Area, _ borderArea: inout Area, _ radius: inout Int) -> Bool
{
    windowArea = Area.zero
    borderArea = Area.zero
    radius = 0

    guard let owner, owner.tree != nil, let leaf = tree_view_find_window(owner, windowID) else { return true }
    if !tree_con_is_visible(leaf) { return false }

    var outer: Con?
    var node = leaf
    while let parent = node.parent, parent.layout == .tabbed, treeBarIsShown(parent) {
        outer = parent
        node = parent
    }

    windowArea = leaf.area
    borderArea = outer?.area ?? leaf.area

    if let outer {
        let wm = window_manager_global()
        let inset = tree_bar_card_inset(outer.area, wm.tab_bar_height, treeBarInset())
        if inset > 0 { radius = wm.tab_bar_window_radius + inset }
    }

    return true
}

/// `tree_render_bars`
func tree_render_bars(_ node: Con)
{
    if con_is_leaf(node) { return }

    if node.layout == .tabbed {
        treeRenderBar(node)
    } else {
        tab_bar_release(node.render.tab_bar)
    }

    for i in 0..<node.child_count {
        tree_render_bars(node.children[i])
    }
}

/// `tree_release_bars`
func tree_release_bars(_ node: Con!)
{
    tab_bar_release(node.render.tab_bar)

    for i in 0..<node.child_count {
        tree_release_bars(node.children[i])
    }
}

/// `tree_collect_window_order`
func treeCollectWindowOrder(_ node: Con, _ order: Int32, _ relative: WindowID, _ list: inout [sa_window_order])
{
    if con_is_leaf(node) {
        if let windowID = node.window_id, windowID != relative { list.append(sa_window_order(a_wid: windowID, order: order, b_wid: relative)) }
        return
    }

    if order == 1 && node.layout == .tabbed {
        if node.child_count != 0 { treeCollectWindowOrder(node.focus[0], order, relative, &list) }
        return
    }

    for i in 0..<node.child_count {
        treeCollectWindowOrder(node.children[i], order, relative, &list)
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

/// `tree_collect_tab_order`
func treeCollectTabOrder(_ node: Con, _ force: Bool, _ list: inout [sa_window_order])
{
    if con_is_leaf(node) { return }

    if node.layout == .tabbed && node.child_count != 0 && tree_con_is_visible(node) {
        let active = node.focus[0]

        let anchor = tree_descend_focused(active)
        let anchorWid = anchor?.window_id
        let cardWid = tab_bar_card_id(node.render.tab_bar)

        if force || node.render.raised != active || node.render.raised_anchor != anchorWid || node.render.raised_card != cardWid {
            node.render.raised = active
            node.render.raised_anchor = anchorWid
            node.render.raised_card = cardWid

            if let anchorWid, let cardWid {
                list.append(sa_window_order(a_wid: anchorWid, order: 1, b_wid: cardWid))
            }

            // NOTE: The other tabs are ordered against the card, or the anchor when there is no card. Without either
            // there is no window to order them against.
            if anchor != nil && node.child_count > 1, let relative = cardWid ?? anchorWid {
                for i in 0..<node.child_count {
                    let next = node.children[i]
                    if next != active { treeCollectWindowOrder(next, -1, relative, &list) }
                }
            }

            if anchor != nil, !con_is_leaf(active), let anchorWid {
                treeCollectWindowOrder(active, 1, anchorWid, &list)
            }
        }
    }

    for i in 0..<node.child_count {
        treeCollectTabOrder(node.children[i], force, &list)
    }
}

/// `tree_raise_tabs`
func tree_raise_tabs(_ node: Con, _ force: Bool)
{
    var list: [sa_window_order] = []
    treeCollectTabOrder(node, force, &list)

    if !list.isEmpty { scripting_addition_order_window_list(list) }
}

//
// NOTE: The card is ordered right below the focused window of the active tab on the main queue, independently
// of tree_raise_tabs. The application raises a window above the other windows of a split tab whenever it gets
// focus, so a card ordered after that (by any redraw of the bar, e.g. on a title change or when another
// application gets focus) lands between them and hides the other windows. They are therefore ordered above
// the focused window again each time the card has been ordered below it.
//

/// `tree_collect_card_order`
func treeCollectCardOrder(_ node: Con, _ windowID: WindowID, _ list: inout [sa_window_order])
{
    if con_is_leaf(node) { return }

    if node.layout == .tabbed && node.child_count != 0 && tree_con_is_visible(node) {
        let active = node.focus[0]
        if !con_is_leaf(active) && tree_descend_focused(active)?.window_id == windowID {
            treeCollectWindowOrder(active, 1, windowID, &list)
            return
        }
    }

    for i in 0..<node.child_count {
        treeCollectCardOrder(node.children[i], windowID, &list)
    }
}

/// `tree_card_did_order`
func tree_card_did_order(_ windowID: WindowID)
{
    guard let owner = window_manager_global().managed_window.find(windowID) else { return }
    if owner.layout != .tree || owner.tree == nil || !space_is_visible(owner.sid) { return }

    var list: [sa_window_order] = []
    treeCollectCardOrder(owner.tree, windowID, &list)
    if !list.isEmpty { scripting_addition_order_window_list(list) }
}

/// `tree_flush`
func tree_flush(_ owner: View)
{
    guard let root = owner.tree else { return }

    var windowList: [window_capture] = []
    treeCaptureWindows(owner, root, &windowList)
    if !windowList.isEmpty { window_manager_animate_window_list(windowList) }

    tree_render_bars(root)
    tree_raise_tabs(root, false)

    if let selected = tree_find_selected(root) { tree_selection_show(selected) }

    if let insertionPoint = owner.insertion_point, let insert = tree_find_window(root, insertionPoint), let insertDir = insert.insert_dir {
        tree_feedback_show(insert, insertDir)
    }

    border_refresh_space(owner.sid)
}

/// `tree_window_did_receive_focus`
func tree_window_did_receive_focus(_ owner: View, _ windowID: WindowID)
{
    guard let node = tree_view_find_window(owner, windowID) else { return }

    tree_select(owner.tree, nil)
    tree_focus(node)

    if !space_is_visible(owner.sid) {
        owner.isDirty = true
        return
    }

    tree_raise_tabs(owner.tree, false)
    tree_render_bars(owner.tree)
}

/// `tree_refresh_for_window`
func tree_refresh_for_window(_ windowID: WindowID?)
{
    guard let windowID, let owner = window_manager_global().managed_window.find(windowID) else { return }
    if owner.layout != .tree || owner.tree == nil { return }

    if space_is_visible(owner.sid) { tree_render_bars(owner.tree) }
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

/// `tree_feedback_show`
func tree_feedback_show(_ node: Con!, _ insertDir: InsertDirection?)
{
    guard let leaf = tree_descend_focused(node), let windowID = leaf.window_id else { return }

    let cid = connection_global()
    let area = node.area
    var frame = CGRect(x: CGFloat(area.x), y: CGFloat(area.y), width: CGFloat(area.w), height: CGFloat(area.h))
    var region: CFTypeRef?
    CGSNewRegionWithRect(&frame, &region)
    let frameRegion = region!
    frame.origin.x = 0; frame.origin.y = 0

    if node.render.feedback_window.id == nil {
        var tags: UInt64 = (1 << 1) | (1 << 9)
        let emptyRegion = CGRegionCreateEmptyRegion()
        var feedbackID: UInt32 = 0
        SLSNewWindowWithOpaqueShapeAndContext(cid, 2, frameRegion, emptyRegion, 13, &tags, 0, 0, 64, &feedbackID, nil)
        node.render.feedback_window.id = WindowID(nonzero: feedbackID)

        sls_window_disable_shadow(feedbackID)
        SLSSetWindowResolution(cid, feedbackID, 1.0)
        SLSSetWindowOpacity(cid, feedbackID, false)
        let context = SLWindowContextCreate(cid, feedbackID, nil)
        node.render.feedback_window.context = context
        context?.setLineWidth(insertFeedbackWidth)
    }

    // NOTE: A window server that did not create the outline leaves no window to draw into or order.
    guard let feedbackWindowID = node.render.feedback_window.id else { return }

    // NOTE: the CGContext calls of the C code did nothing without a context
    let context = node.render.feedback_window.context
    let color = window_manager_global().insert_feedback_color
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

    SLSSetWindowLevel(cid, feedbackWindowID.rawValue, window_level(windowID))
    SLSSetWindowSubLevel(cid, feedbackWindowID.rawValue, window_sub_level(windowID))
    SLSOrderWindow(cid, feedbackWindowID.rawValue, 1, windowID.rawValue)
}

/// `tree_feedback_hide`
func tree_feedback_hide(_ node: Con!)
{
    treeFeedbackDestroy(node)
}

/// `tree_selection_show`
func tree_selection_show(_ node: Con)
{
    tree_feedback_show(node, nil)
}
