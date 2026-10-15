import CoreGraphics
import Foundation
import YabaiC
import YabaiCore

//
// NOTE: A view is the layout state of one space: its tree, its area and its padding and gap. Ported from src/view.c.
// struct view stays C while border.c, tab_bar.c, mouse_handler.c and rule.c read its fields.
//

/// `view_check_flag`
func hasViewFlag(_ target: View, _ flag: view_flag) -> Bool
{
    return target.pointee.flags & UInt64(flag.rawValue) != 0
}

/// `view_set_flag`
func setViewFlag(_ target: View, _ flag: view_flag)
{
    target.pointee.flags |= UInt64(flag.rawValue)
}

/// `view_clear_flag`
func clearViewFlag(_ target: View, _ flag: view_flag)
{
    target.pointee.flags &= ~UInt64(flag.rawValue)
}

/// `view_window_gap`
@_cdecl("view_window_gap")
func view_window_gap(_ target: View) -> Int32
{
    return ViewArea.windowGap(gapEnabled: hasViewFlag(target, VIEW_ENABLE_GAP), windowGap: target.pointee.window_gap)
}

/// `view_add_window`
@_cdecl("view_add_window")
func view_add_window(_ target: View, _ win: UnsafeMutablePointer<window>, _ insertionPoint: UInt32)
{
    tree_add_window(target, win, insertionPoint)
    if !view_update_auto_padding(target) { tree_view_update(target) }
    setViewFlag(target, VIEW_IS_DIRTY)
}

/// `view_remove_window`
@discardableResult
@_cdecl("view_remove_window")
func view_remove_window(_ target: View, _ win: UnsafeMutablePointer<window>) -> Bool
{
    if !tree_remove_window(target, win) { return false }

    if !view_update_auto_padding(target) { tree_view_update(target) }
    setViewFlag(target, VIEW_IS_DIRTY)
    return true
}

/// `view_find_window_list`
@_cdecl("view_find_window_list")
func view_find_window_list(_ target: View, _ windowCount: UnsafeMutablePointer<Int32>) -> UnsafeMutablePointer<UInt32>?
{
    return tree_view_window_list(target, windowCount)
}

/// `view_is_invalid`
@_cdecl("view_is_invalid")
func view_is_invalid(_ target: View) -> Bool
{
    return !hasViewFlag(target, VIEW_IS_VALID)
}

/// `view_is_dirty`
@_cdecl("view_is_dirty")
func view_is_dirty(_ target: View) -> Bool
{
    return hasViewFlag(target, VIEW_IS_DIRTY)
}

/// `view_flush`: lays out the tree when the space is visible, otherwise keeps the view dirty until it is.
@_cdecl("view_flush")
func view_flush(_ target: View)
{
    if space_is_visible(target.pointee.sid) {
        tree_flush(target)
        clearViewFlag(target, VIEW_IS_DIRTY)
    } else {
        setViewFlag(target, VIEW_IS_DIRTY)
    }
}

/// `view_auto_padding_applies`
@_cdecl("view_auto_padding_applies")
func view_auto_padding_applies(_ layout: view_type, _ autoPadding: Bool, _ tiledCount: Int32) -> Bool
{
    return ViewArea.autoPaddingApplies(isTree: layout == VIEW_TREE, autoPadding: autoPadding, tiledCount: Int(tiledCount))
}

/// `view_tiled_count`
@_cdecl("view_tiled_count")
func view_tiled_count(_ target: View) -> Int32
{
    return tree_view_tiled_count(target)
}

/// `view_root_area`: the area of the windows of a view inside the frame of its display.
func view_root_area(_ target: View, _ frame: CGRect) -> area
{
    let root = ViewArea.rootArea(Area(frame),
                                 paddingEnabled: hasViewFlag(target, VIEW_ENABLE_PADDING),
                                 unpadded: hasViewFlag(target, VIEW_IS_UNPADDED),
                                 top: target.pointee.top_padding,
                                 bottom: target.pointee.bottom_padding,
                                 left: target.pointee.left_padding,
                                 right: target.pointee.right_padding)

    return area(x: root.x, y: root.y, w: root.w, h: root.h)
}

/// `view_update_with_auto_padding`
private func view_update_with_auto_padding(_ target: View, _ unpadded: Bool)
{
    if unpadded {
        setViewFlag(target, VIEW_IS_UNPADDED)
    } else {
        clearViewFlag(target, VIEW_IS_UNPADDED)
    }

    let did = space_display_id(target.pointee.sid)
    let frame = display_bounds_constrained(did, false)
    target.pointee.area = view_root_area(target, frame)

    tree_view_update(target)
    setViewFlag(target, VIEW_IS_VALID)
    setViewFlag(target, VIEW_IS_DIRTY)
}

//
// NOTE: Re-layout the view if the tiled window count crossed the auto_padding threshold.
// Returns true if it did, in which case the whole tree must be flushed.
//

/// `view_update_auto_padding`
@_cdecl("view_update_auto_padding")
func view_update_auto_padding(_ target: View) -> Bool
{
    let unpadded = view_auto_padding_applies(target.pointee.layout, target.pointee.auto_padding, view_tiled_count(target))
    if unpadded == hasViewFlag(target, VIEW_IS_UNPADDED) { return false }

    view_update_with_auto_padding(target, unpadded)
    return true
}

/// `view_update`
@_cdecl("view_update")
func view_update(_ target: View)
{
    view_update_with_auto_padding(target, view_auto_padding_applies(target.pointee.layout, target.pointee.auto_padding, view_tiled_count(target)))
}

/// `view_update_and_flush`
@_cdecl("view_update_and_flush")
func view_update_and_flush(_ target: View)
{
    view_update(target)
    view_flush(target)
}

/// `view_create`: the view of a space, with the layout of the space manager for user spaces.
@_cdecl("view_create")
func viewCreate(_ sid: UInt64) -> View
{
    let target = calloc(1, MemoryLayout<view>.stride)!.bindMemory(to: view.self, capacity: 1)

    target.pointee.sid = sid
    target.pointee.uuid = SLS.spaceNameObject(connection_global(), sid).map { Unmanaged.passRetained($0) }

    setViewFlag(target, VIEW_ENABLE_PADDING)
    setViewFlag(target, VIEW_ENABLE_GAP)

    if space_is_user(target.pointee.sid) {
        let sm = space_manager_global()

        target.pointee.layout         = sm.layout
        target.pointee.top_padding    = sm.top_padding
        target.pointee.bottom_padding = sm.bottom_padding
        target.pointee.left_padding   = sm.left_padding
        target.pointee.right_padding  = sm.right_padding
        target.pointee.window_gap     = sm.window_gap
        target.pointee.auto_padding   = sm.auto_padding
        view_update(target)
    } else {
        target.pointee.layout = VIEW_FLOAT
    }

    return target
}

/// `view_clear`
@_cdecl("view_clear")
func view_clear(_ target: View)
{
    target.pointee.insertion_point = 0
    tree_view_clear(target)
    view_update(target)
}

/// `view_destroy`: releases the name of the space. The struct itself is not freed, as before the port.
@_cdecl("view_destroy")
func view_destroy(_ target: View)
{
    tree_view_clear(target)

    target.pointee.uuid?.release()
}
