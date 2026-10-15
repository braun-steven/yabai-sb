import CoreGraphics
import Foundation
import CPrivate
import YabaiC

//
// NOTE: Applies the container trees of Tree.swift to the screen: the tree of a view, window frames,
// tab bars, the stacking order of tabs, the outline of selected containers and the JSON of a tree.
// A view that uses the 'tree' layout owns its root container in view->tree. Ported from src/tree_view.c.
//

/// `tree_append_title`
private func treeAppendTitle(_ string: CFMutableString, _ node: Con)
{
    if con_is_leaf(node) {
        if let target = window_manager_find_window(window_manager_global(), node.pointee.window_id),
           let application = target.pointee.application, let name = application.pointee.name {
            CFStringAppendCString(string, name, CFStringBuiltInEncodings.UTF8.rawValue)
        }
        return
    }

    let layout = node.pointee.layout
    CFStringAppendCString(string, layout == CON_SPLITH ? "H[" : layout == CON_SPLITV ? "V[" : "T[", CFStringBuiltInEncodings.UTF8.rawValue)

    for i in 0..<Int(node.pointee.child_count) {
        if i > 0 { CFStringAppendCString(string, " ", CFStringBuiltInEncodings.UTF8.rawValue) }
        treeAppendTitle(string, node.pointee.children[i]!)
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
    if con_is_leaf(node) { return tab_bar_copy_title(node.pointee.window_id)?.takeRetainedValue() }

    let string = CFStringCreateMutable(nil, 0)!
    treeAppendTitle(string, node)
    return string
}

/// `tree_feedback_destroy`
func treeFeedbackDestroy(_ node: Con)
{
    if node.pointee.render.feedback_window.id == 0 { return }

    SLSOrderWindow(connection_global(), node.pointee.render.feedback_window.id, 0, 0)
    node.pointee.render.feedback_window.context?.release()
    SLSReleaseWindow(connection_global(), node.pointee.render.feedback_window.id)
    node.pointee.render.feedback_window = feedback_window()
}

/// `tree_bar_height`
private func treeBarHeight() -> Int32
{
    return tab_bar_is_enabled() ? window_manager_global().pointee.tab_bar_height : 0
}

/// `tree_bar_inset`
private func treeBarInset() -> Int32
{
    return tab_bar_is_enabled() ? tab_bar_card_padding() : 0
}

/// `tree_default_layout`
private func treeDefaultLayout(_ owner: View) -> con_layout
{
    switch space_manager_global().pointee.tree_default_orientation {
    case TREE_ORIENTATION_HORIZONTAL: return CON_SPLITH
    case TREE_ORIENTATION_VERTICAL:   return CON_SPLITV
    default:                          break
    }

    return owner.pointee.area.w >= owner.pointee.area.h ? CON_SPLITH : CON_SPLITV
}

/// `tree_view_root`
func tree_view_root(_ owner: View) -> Con
{
    if owner.pointee.tree == nil {
        owner.pointee.tree = con_create(treeDefaultLayout(owner))
        owner.pointee.tree.pointee.area = owner.pointee.area
    }

    return owner.pointee.tree
}

/// `tree_view_update`
@_cdecl("tree_view_update")
func tree_view_update(_ owner: View!)
{
    guard let root = owner.pointee.tree else { return }
    tree_update(root, owner.pointee.area, view_window_gap(owner), treeBarHeight(), window_manager_global().pointee.tab_bar_offset, treeBarInset())
}

/// `tree_unmanage_windows`
private func treeUnmanageWindows(_ node: Con)
{
    if con_is_leaf(node) {
        window_manager_remove_managed_window(window_manager_global(), node.pointee.window_id)
        return
    }

    for i in 0..<Int(node.pointee.child_count) {
        treeUnmanageWindows(node.pointee.children[i]!)
    }
}

/// `tree_view_clear`
func tree_view_clear(_ owner: View)
{
    guard let root = owner.pointee.tree else { return }

    treeUnmanageWindows(root)
    con_free(root)
    owner.pointee.tree = nil
}

/// `tree_view_find_window`
@_cdecl("tree_view_find_window")
func tree_view_find_window(_ owner: View!, _ windowID: UInt32) -> Con!
{
    guard let root = owner.pointee.tree else { return nil }
    return tree_find_window(root, windowID)
}

//
// NOTE: A new window becomes the focused child of its containers, as i3 focuses new windows, unless
// the focused window is on this space: a window that is moved here or stops floating then stays
// behind it, so that the focused window is not hidden in another tab.
//

/// `tree_focus_new_window`
private func treeFocusNewWindow(_ root: Con, _ node: Con, _ windowID: UInt32)
{
    tree_focus(node)

    let focusedWindowID = window_manager_global().pointee.focused_window_id
    if windowID != focusedWindowID, let focused = tree_find_window(root, focusedWindowID) {
        tree_focus(focused)
    }
}

/// `tree_view_reset_empty_root`
private func treeViewResetEmptyRoot(_ owner: View, _ root: Con)
{
    if root.pointee.child_count != 0 { return }

    root.pointee.layout = treeDefaultLayout(owner)
    root.pointee.last_split = root.pointee.layout
}

//
// NOTE: A new window opens where tree_open_con puts it: next to the focused window, or next to
// the selected container (focus parent). An insertion point set with 'window --insert' or by a
// mouse drop places it on that side of its window instead, and the insertion point passed in is
// used for windows that are restored or moved here, so they open next to that window.
//

/// `tree_add_window`
func tree_add_window(_ owner: View, _ target: Window, _ insertionPoint: UInt32)
{
    let root = tree_view_root(owner)
    if tree_find_window(root, target.pointee.id) != nil { return }

    let node = con_create(CON_SPLITH)!
    node.pointee.window_id = target.pointee.id

    treeViewResetEmptyRoot(owner, root)

    if owner.pointee.insertion_point != 0, let anchor = tree_find_window(root, owner.pointee.insertion_point), anchor.pointee.insert_dir != 0 {
        let direction = anchor.pointee.insert_dir
        anchor.pointee.insert_dir = 0
        treeFeedbackDestroy(anchor)
        owner.pointee.insertion_point = 0

        tree_insert_relative(anchor, node, direction)
        treeFocusNewWindow(root, node, target.pointee.id)
        return
    }

    var anchor: Con? = insertionPoint != 0 ? tree_find_window(root, insertionPoint) : nil

    if anchor == nil, let selected = tree_find_selected(root), !con_is_leaf(selected) {
        anchor = selected
    }

    if anchor == nil { anchor = tree_find_window(root, window_manager_global().pointee.focused_window_id) }
    if anchor == nil { anchor = tree_descend_focused(root) }

    tree_open_con(root, node, anchor, space_manager_global().pointee.tree_autotiling)
    treeFocusNewWindow(root, node, target.pointee.id)
}

//
// NOTE: A container that moves here from another display, with its windows already moved to the
// space of this view. It keeps its structure and arrives on the side it comes from.
//

/// `tree_view_attach_from_direction`
func tree_view_attach_from_direction(_ owner: View, _ node: Con, _ direction: Int32)
{
    let root = tree_view_root(owner)
    treeViewResetEmptyRoot(owner, root)
    tree_attach_from_direction(root, node, direction)
}

/// `tree_remove_window`
func tree_remove_window(_ owner: View, _ target: Window) -> Bool
{
    guard let node = tree_find_window(owner.pointee.tree, target.pointee.id) else { return false }

    if owner.pointee.insertion_point == target.pointee.id { owner.pointee.insertion_point = 0 }

    tree_detach(node)
    con_free(node)
    tree_flatten(owner.pointee.tree)

    return true
}

/// `tree_append_window_list`
private func treeAppendWindowList(_ node: Con, _ windowList: inout [UInt32])
{
    if con_is_leaf(node) {
        windowList.append(node.pointee.window_id)
        return
    }

    for i in 0..<Int(node.pointee.child_count) {
        treeAppendWindowList(node.pointee.children[i]!, &windowList)
    }
}

/// `tree_view_window_list`: the windows of the tree in its order.
func treeViewWindowList(_ owner: View) -> [UInt32]
{
    var windowList: [UInt32] = []
    if let root = owner.pointee.tree { treeAppendWindowList(root, &windowList) }
    return windowList
}

/// `tree_view_window_list`: the list of treeViewWindowList in temporary storage, for C.
@_cdecl("tree_view_window_list")
func tree_view_window_list(_ owner: View!, _ windowCount: UnsafeMutablePointer<Int32>!) -> UnsafeMutablePointer<UInt32>!
{
    let windowList = treeViewWindowList(owner)
    windowCount.pointee = Int32(windowList.count)
    return temporaryList(windowList)
}

//
// NOTE: Counts the areas auto_padding cares about. A tabbed container shows one tab at a time,
// so it is a single area no matter how many tabs it holds.
//

/// `tree_tiled_count`
private func treeTiledCount(_ node: Con) -> Int32
{
    if con_is_leaf(node) { return node.pointee.zoom == CON_ZOOM_FULLSCREEN ? 0 : 1 }

    var count: Int32 = 0
    for i in 0..<Int(node.pointee.child_count) {
        count += treeTiledCount(node.pointee.children[i]!)
    }

    return node.pointee.layout == CON_TABBED && count > 1 ? 1 : count
}

/// `tree_view_tiled_count`
@_cdecl("tree_view_tiled_count")
func tree_view_tiled_count(_ owner: View!) -> Int32
{
    guard let root = owner.pointee.tree else { return 0 }
    return treeTiledCount(root)
}

/// `tree_con_frame`
func tree_con_frame(_ owner: View, _ node: Con) -> area
{
    if node.pointee.zoom == CON_ZOOM_FULLSCREEN { return owner.pointee.tree.pointee.area }
    if node.pointee.zoom == CON_ZOOM_PARENT, let parent = node.pointee.parent { return parent.pointee.area }
    return node.pointee.area
}

/// `AX_DIFF` (view.h)
private func axDiff(_ a: Float, _ b: CGFloat) -> Bool
{
    return abs(CGFloat(a) - b) >= 1.5
}

/// `tree_window_needs_flush`
func tree_window_needs_flush(_ owner: View, _ windowID: UInt32, _ frame: CGRect) -> Bool
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
        if let target = window_manager_find_window(window_manager_global(), node.pointee.window_id) {
            let area = tree_con_frame(owner, node)
            windowList.append(window_capture(window: target, x: area.x, y: area.y, w: area.w, h: area.h))
        }
        return
    }

    for i in 0..<Int(node.pointee.child_count) {
        treeCaptureWindows(owner, node.pointee.children[i]!, &windowList)
    }
}

/// `tree_has_zoom`
func treeHasZoom(_ node: Con, _ zoom: con_zoom) -> Bool
{
    if con_is_leaf(node) { return zoom == CON_ZOOM_NONE ? node.pointee.zoom != CON_ZOOM_NONE : node.pointee.zoom == zoom }

    for i in 0..<Int(node.pointee.child_count) {
        if treeHasZoom(node.pointee.children[i]!, zoom) { return true }
    }

    return false
}

/// `tree_root_of`
private func treeRootOf(_ node: Con) -> Con
{
    var node = node
    while let parent = node.pointee.parent { node = parent }
    return node
}

/// `tree_contains_window`
func treeContainsWindow(_ node: Con, _ windowID: UInt32) -> Bool
{
    return windowID != 0 && tree_find_window(node, windowID) != nil
}

//
// NOTE: A zoomed window covers the bars of the containers it belongs to, and a fullscreen
// window covers every bar on the space.
//

/// `tree_bar_is_shown`
private func treeBarIsShown(_ node: Con) -> Bool
{
    return tab_bar_is_enabled() &&
           node.pointee.layout == CON_TABBED &&
           node.pointee.child_count > 0 &&
           node.pointee.area.h > Float(2 * window_manager_global().pointee.tab_bar_height) &&
           tree_con_is_visible(node) &&
           !treeHasZoom(node, CON_ZOOM_NONE) &&
           !treeHasZoom(treeRootOf(node), CON_ZOOM_FULLSCREEN)
}

//
// NOTE: The redraw callback of the tab bar of a container (TabBar.swift calls it with the container as
// the owner); the container outlives its bar, which con_free releases.
//

private func treeRenderBarCallback(_ owner: UnsafeMutableRawPointer?)
{
    treeRenderBar(owner!.assumingMemoryBound(to: con.self))
}

/// `tree_render_bar`
private func treeRenderBar(_ node: Con)
{
    if !treeBarIsShown(node) {
        tab_bar_hide(&node.pointee.render.tab_bar)
        return
    }

    let wm = window_manager_global()!
    let entryCount = min(node.pointee.child_count, TAB_BAR_MAX_ENTRY_COUNT)
    let hasFocus = treeContainsWindow(node, wm.pointee.focused_window_id)
    let active = node.pointee.focus[0]

    // NOTE: the titles stay alive in this array until tab_bar_render has drawn them
    var titleList: [CFString?] = []
    var entryList: [tab_bar_entry] = []

    for i in 0..<Int(entryCount) {
        let next = node.pointee.children[i]!
        let leaf = tree_descend_focused(next)
        let title = tree_copy_title(next)
        titleList.append(title)

        entryList.append(tab_bar_entry(
            focus_wid: leaf?.pointee.window_id ?? 0,
            title: title.map { Unmanaged.passUnretained($0) },
            icon: con_is_leaf(next) ? tab_bar_icon(next.pointee.window_id) : nil,
            state: next != active ? TAB_BAR_UNFOCUSED : hasFocus ? TAB_BAR_FOCUSED : TAB_BAR_INACTIVE))
    }

    node.pointee.render.tab_bar.owner = UnsafeMutableRawPointer(node)
    node.pointee.render.tab_bar.redraw = treeRenderBarCallback

    let above = tree_descend_focused(node)
    let area = node.pointee.area
    let inset = Float(tree_bar_card_inset(area, wm.pointee.tab_bar_height, treeBarInset()))
    let card = CGRect(x: CGFloat(area.x), y: CGFloat(area.y), width: CGFloat(area.w), height: CGFloat(area.h))
    let frame = CGRect(x: CGFloat(area.x + inset), y: CGFloat(area.y + inset), width: CGFloat(area.w - 2 * inset), height: CGFloat(wm.pointee.tab_bar_height))
    entryList.withUnsafeMutableBufferPointer { entries in
        tab_bar_render(&node.pointee.render.tab_bar, frame, card, above?.pointee.window_id ?? 0, entries.baseAddress, entryCount)
    }

    withExtendedLifetime(titleList) {}
}

//
// NOTE: The area a window border wraps. A window in a tabbed container is wrapped together with the bars of the
// containers it is the active tab of, i.e. the whole container, around its backdrop card when it has one (then
// radius is the corner radius of the card, otherwise 0 for the radius of the window). A window that is not in the
// tree gets empty areas, i.e. a border around the window itself. Returns false for a window of a hidden tab, which
// gets no border.
//

/// `tree_window_border_area`
@_cdecl("tree_window_border_area")
func tree_window_border_area(_ owner: View!, _ windowID: UInt32, _ windowArea: UnsafeMutablePointer<area>!, _ borderArea: UnsafeMutablePointer<area>!, _ radius: UnsafeMutablePointer<Int32>!) -> Bool
{
    windowArea.pointee = area()
    borderArea.pointee = area()
    radius.pointee = 0

    guard let owner, owner.pointee.tree != nil, let leaf = tree_view_find_window(owner, windowID) else { return true }
    if !tree_con_is_visible(leaf) { return false }

    var outer: Con?
    var node = leaf
    while let parent = node.pointee.parent, parent.pointee.layout == CON_TABBED, treeBarIsShown(parent) {
        outer = parent
        node = parent
    }

    windowArea.pointee = leaf.pointee.area
    borderArea.pointee = outer?.pointee.area ?? leaf.pointee.area

    if let outer {
        let wm = window_manager_global()!
        let inset = tree_bar_card_inset(outer.pointee.area, wm.pointee.tab_bar_height, treeBarInset())
        if inset > 0 { radius.pointee = wm.pointee.tab_bar_window_radius + inset }
    }

    return true
}

/// `tree_render_bars`
func tree_render_bars(_ node: Con)
{
    if con_is_leaf(node) { return }

    if node.pointee.layout == CON_TABBED {
        treeRenderBar(node)
    } else {
        tab_bar_release(&node.pointee.render.tab_bar)
    }

    for i in 0..<Int(node.pointee.child_count) {
        tree_render_bars(node.pointee.children[i]!)
    }
}

/// `tree_release_bars`
@_cdecl("tree_release_bars")
func tree_release_bars(_ node: Con!)
{
    tab_bar_release(&node.pointee.render.tab_bar)

    for i in 0..<Int(node.pointee.child_count) {
        tree_release_bars(node.pointee.children[i]!)
    }
}

/// `tree_collect_window_order`
func treeCollectWindowOrder(_ node: Con, _ order: Int32, _ relative: UInt32, _ list: inout [sa_window_order])
{
    if con_is_leaf(node) {
        if node.pointee.window_id != relative { list.append(sa_window_order(a_wid: node.pointee.window_id, order: order, b_wid: relative)) }
        return
    }

    if order == 1 && node.pointee.layout == CON_TABBED {
        if node.pointee.child_count != 0 { treeCollectWindowOrder(node.pointee.focus[0]!, order, relative, &list) }
        return
    }

    for i in 0..<Int(node.pointee.child_count) {
        treeCollectWindowOrder(node.pointee.children[i]!, order, relative, &list)
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

    if node.pointee.layout == CON_TABBED && node.pointee.child_count != 0 && tree_con_is_visible(node) {
        let active = node.pointee.focus[0]!

        let anchor = tree_descend_focused(active)
        let anchorWid = anchor?.pointee.window_id ?? 0
        let cardWid = tab_bar_card_id(&node.pointee.render.tab_bar)

        if force || node.pointee.render.raised != active || node.pointee.render.raised_anchor != anchorWid || node.pointee.render.raised_card != cardWid {
            node.pointee.render.raised = active
            node.pointee.render.raised_anchor = anchorWid
            node.pointee.render.raised_card = cardWid

            if anchor != nil && cardWid != 0 {
                list.append(sa_window_order(a_wid: anchorWid, order: 1, b_wid: cardWid))
            }

            if anchor != nil && node.pointee.child_count > 1 {
                for i in 0..<Int(node.pointee.child_count) {
                    let next = node.pointee.children[i]!
                    if next != active { treeCollectWindowOrder(next, -1, cardWid != 0 ? cardWid : anchorWid, &list) }
                }
            }

            if let anchor, !con_is_leaf(active) {
                treeCollectWindowOrder(active, 1, anchor.pointee.window_id, &list)
            }
        }
    }

    for i in 0..<Int(node.pointee.child_count) {
        treeCollectTabOrder(node.pointee.children[i]!, force, &list)
    }
}

/// `tree_raise_tabs`
func tree_raise_tabs(_ node: Con, _ force: Bool)
{
    var list: [sa_window_order] = []
    treeCollectTabOrder(node, force, &list)

    if !list.isEmpty { scripting_addition_order_window_list(&list, Int32(list.count)) }
}

/// `tree_flush`
func tree_flush(_ owner: View)
{
    guard let root = owner.pointee.tree else { return }

    var windowList: [window_capture] = []
    treeCaptureWindows(owner, root, &windowList)
    if !windowList.isEmpty { window_manager_animate_window_list(&windowList, Int32(windowList.count)) }

    tree_render_bars(root)
    tree_raise_tabs(root, false)

    if let selected = tree_find_selected(root) { tree_selection_show(selected) }

    if owner.pointee.insertion_point != 0, let insert = tree_find_window(root, owner.pointee.insertion_point), insert.pointee.insert_dir != 0 {
        tree_feedback_show(insert, insert.pointee.insert_dir)
    }

    border_refresh_space(owner.pointee.sid)
}

/// `tree_window_did_receive_focus`
func tree_window_did_receive_focus(_ owner: View, _ windowID: UInt32)
{
    guard let node = tree_view_find_window(owner, windowID) else { return }

    tree_select(owner.pointee.tree, nil)
    tree_focus(node)

    if !space_is_visible(owner.pointee.sid) {
        setViewFlag(owner, VIEW_IS_DIRTY)
        return
    }

    tree_raise_tabs(owner.pointee.tree, false)
    tree_render_bars(owner.pointee.tree)
}

/// `tree_refresh_for_window`
@_cdecl("tree_refresh_for_window")
func tree_refresh_for_window(_ windowID: UInt32)
{
    if windowID == 0 { return }

    var key = windowID
    guard let owner = table_find(&window_manager_global().pointee.managed_window, &key)?.assumingMemoryBound(to: view.self) else { return }
    if owner.pointee.layout != VIEW_TREE || owner.pointee.tree == nil { return }

    if space_is_visible(owner.pointee.sid) { tree_render_bars(owner.pointee.tree) }
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
@_cdecl("tree_feedback_show")
func tree_feedback_show(_ node: Con!, _ insertDir: Int32)
{
    guard let leaf = tree_descend_focused(node), con_is_leaf(leaf) else { return }

    let cid = connection_global()
    let area = node.pointee.area
    var frame = CGRect(x: CGFloat(area.x), y: CGFloat(area.y), width: CGFloat(area.w), height: CGFloat(area.h))
    var region: CFTypeRef?
    CGSNewRegionWithRect(&frame, &region)
    let frameRegion = region!
    frame.origin.x = 0; frame.origin.y = 0

    if node.pointee.render.feedback_window.id == 0 {
        var tags: UInt64 = (1 << 1) | (1 << 9)
        let emptyRegion = CGRegionCreateEmptyRegion()
        SLSNewWindowWithOpaqueShapeAndContext(cid, 2, frameRegion, emptyRegion, 13, &tags, 0, 0, 64, &node.pointee.render.feedback_window.id, nil)

        sls_window_disable_shadow(node.pointee.render.feedback_window.id)
        SLSSetWindowResolution(cid, node.pointee.render.feedback_window.id, 1.0)
        SLSSetWindowOpacity(cid, node.pointee.render.feedback_window.id, false)
        let context = SLWindowContextCreate(cid, node.pointee.render.feedback_window.id, nil)
        node.pointee.render.feedback_window.context = context.map { Unmanaged.passRetained($0) }
        context?.setLineWidth(insertFeedbackWidth)
    }

    // NOTE: the CGContext calls of the C code did nothing without a context
    let context = node.pointee.render.feedback_window.context?.takeUnretainedValue()
    let color = window_manager_global().pointee.insert_feedback_color
    context?.setFillColor(red: CGFloat(color.r), green: CGFloat(color.g), blue: CGFloat(color.b), alpha: CGFloat(color.a * (insertDir != 0 ? 0.25 : 0.15)))
    context?.setStrokeColor(red: CGFloat(color.r), green: CGFloat(color.g), blue: CGFloat(color.b), alpha: CGFloat(color.a))

    var clipX = -0.5 * insertFeedbackWidth
    var clipY = -0.5 * insertFeedbackWidth
    var clipW = insertFeedbackWidth
    var clipH = insertFeedbackWidth
    let midx = frame.midX
    let midy = frame.midY

    switch insertDir {
    case DIR_NORTH: clipY = midy - 0.5 * insertFeedbackWidth
    case DIR_EAST:  clipX = midx - 0.5 * insertFeedbackWidth
    case DIR_SOUTH: clipH = -midy + insertFeedbackWidth
    case DIR_WEST:  clipW = -midx + insertFeedbackWidth
    default:        break
    }

    let rect = CGRect(x: 0.5 * insertFeedbackWidth, y: 0.5 * insertFeedbackWidth, width: frame.size.width - insertFeedbackWidth, height: frame.size.height - insertFeedbackWidth)
    let fill = rect.insetBy(dx: 0.5 * insertFeedbackWidth, dy: 0.5 * insertFeedbackWidth)
    let clip = CGRect(x: rect.origin.x + clipX, y: rect.origin.y + clipY, width: rect.size.width + clipW, height: rect.size.height + clipH)
    let path = CGPath(roundedRect: rect, cornerWidth: CGFloat(cgrect_clamp_x_radius(rect, insertFeedbackRadius)), cornerHeight: CGFloat(cgrect_clamp_y_radius(rect, insertFeedbackRadius)), transform: nil)

    SLSDisableUpdate(cid)
    SLSSetWindowShape(cid, node.pointee.render.feedback_window.id, 0.0, 0.0, frameRegion)
    context?.clear(frame)
    context?.clip(to: clip)
    context?.fill(fill)
    context?.addPath(path)
    context?.strokePath()
    context?.resetClip()
    context?.flush()
    SLSReenableUpdate(cid)

    SLSSetWindowLevel(cid, node.pointee.render.feedback_window.id, window_level(leaf.pointee.window_id))
    SLSSetWindowSubLevel(cid, node.pointee.render.feedback_window.id, window_sub_level(leaf.pointee.window_id))
    SLSOrderWindow(cid, node.pointee.render.feedback_window.id, 1, leaf.pointee.window_id)
}

/// `tree_feedback_hide`
@_cdecl("tree_feedback_hide")
func tree_feedback_hide(_ node: Con!)
{
    treeFeedbackDestroy(node)
}

/// `tree_selection_show`
func tree_selection_show(_ node: Con)
{
    tree_feedback_show(node, 0)
}
