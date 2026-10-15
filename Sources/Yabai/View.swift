import CoreGraphics
import Foundation
import YabaiC
import YabaiCore

//
// NOTE: A view is the layout state of one space: its tree, its area and its padding and gap. Ported from src/view.c.
//

/// `struct view`
final class View
{
    var uuid: CFString?
    var sid: UInt64 = 0
    var area = YabaiC.area()
    var tree: Con!
    var insertion_point: UInt32 = 0
    var layout = VIEW_DEFAULT
    var top_padding: Int32 = 0
    var bottom_padding: Int32 = 0
    var left_padding: Int32 = 0
    var right_padding: Int32 = 0
    var window_gap: Int32 = 0
    var auto_padding = false
    var flags: UInt64 = 0

    /// The view itself, for the code that still reads it like the C pointer.
    var pointee: View { self }
}

extension View: Equatable
{
    static func == (a: View, b: View) -> Bool { a === b }
}

/// `view_spacing`: the padding or gap of the view that flag names.
func view_spacing(_ flag: view_flag) -> ReferenceWritableKeyPath<View, Int32>
{
    switch flag {
    case VIEW_TOP_PADDING:    \.top_padding
    case VIEW_BOTTOM_PADDING: \.bottom_padding
    case VIEW_LEFT_PADDING:   \.left_padding
    case VIEW_RIGHT_PADDING:  \.right_padding
    case VIEW_WINDOW_GAP:     \.window_gap
    default:                  preconditionFailure("view_spacing: \(flag.rawValue) is not a spacing")
    }
}

/// `view_check_flag`
func hasViewFlag(_ target: View, _ flag: view_flag) -> Bool
{
    return target.flags & UInt64(flag.rawValue) != 0
}

/// `view_set_flag`
func setViewFlag(_ target: View, _ flag: view_flag)
{
    target.flags |= UInt64(flag.rawValue)
}

/// `view_clear_flag`
func clearViewFlag(_ target: View, _ flag: view_flag)
{
    target.flags &= ~UInt64(flag.rawValue)
}

/// `view_window_gap`
func view_window_gap(_ target: View) -> Int32
{
    return ViewArea.windowGap(gapEnabled: hasViewFlag(target, VIEW_ENABLE_GAP), windowGap: target.window_gap)
}

/// `view_add_window`
func view_add_window(_ target: View, _ win: Window, _ insertionPoint: UInt32)
{
    tree_add_window(target, win, insertionPoint)
    if !view_update_auto_padding(target) { tree_view_update(target) }
    setViewFlag(target, VIEW_IS_DIRTY)
}

/// `view_remove_window`
@discardableResult
func view_remove_window(_ target: View, _ win: Window) -> Bool
{
    if !tree_remove_window(target, win) { return false }

    if !view_update_auto_padding(target) { tree_view_update(target) }
    setViewFlag(target, VIEW_IS_DIRTY)
    return true
}

/// `view_find_window_list`
func view_find_window_list(_ target: View) -> [UInt32]
{
    return treeViewWindowList(target)
}

/// `view_is_invalid`
func view_is_invalid(_ target: View) -> Bool
{
    return !hasViewFlag(target, VIEW_IS_VALID)
}

/// `view_is_dirty`
func view_is_dirty(_ target: View) -> Bool
{
    return hasViewFlag(target, VIEW_IS_DIRTY)
}

/// `view_flush`: lays out the tree when the space is visible, otherwise keeps the view dirty until it is.
func view_flush(_ target: View)
{
    if space_is_visible(target.sid) {
        tree_flush(target)
        clearViewFlag(target, VIEW_IS_DIRTY)
    } else {
        setViewFlag(target, VIEW_IS_DIRTY)
    }
}

/// `view_auto_padding_applies`
func view_auto_padding_applies(_ layout: view_type, _ autoPadding: Bool, _ tiledCount: Int32) -> Bool
{
    return ViewArea.autoPaddingApplies(isTree: layout == VIEW_TREE, autoPadding: autoPadding, tiledCount: Int(tiledCount))
}

/// `view_tiled_count`
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
                                 top: target.top_padding,
                                 bottom: target.bottom_padding,
                                 left: target.left_padding,
                                 right: target.right_padding)

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

    let did = space_display_id(target.sid)
    let frame = display_bounds_constrained(did, false)
    target.area = view_root_area(target, frame)

    tree_view_update(target)
    setViewFlag(target, VIEW_IS_VALID)
    setViewFlag(target, VIEW_IS_DIRTY)
}

//
// NOTE: Re-layout the view if the tiled window count crossed the auto_padding threshold.
// Returns true if it did, in which case the whole tree must be flushed.
//

/// `view_update_auto_padding`
func view_update_auto_padding(_ target: View) -> Bool
{
    let unpadded = view_auto_padding_applies(target.layout, target.auto_padding, view_tiled_count(target))
    if unpadded == hasViewFlag(target, VIEW_IS_UNPADDED) { return false }

    view_update_with_auto_padding(target, unpadded)
    return true
}

/// `view_update`
func view_update(_ target: View)
{
    view_update_with_auto_padding(target, view_auto_padding_applies(target.layout, target.auto_padding, view_tiled_count(target)))
}

/// `view_update_and_flush`
func view_update_and_flush(_ target: View)
{
    view_update(target)
    view_flush(target)
}

/// `view_create`: the view of a space, with the layout of the space manager for user spaces.
func view_create(_ sid: UInt64) -> View
{
    let target = View()

    target.sid = sid
    target.uuid = SLS.spaceNameObject(connection_global(), sid)

    setViewFlag(target, VIEW_ENABLE_PADDING)
    setViewFlag(target, VIEW_ENABLE_GAP)

    if space_is_user(target.sid) {
        let sm = space_manager_global()

        target.layout         = sm.layout
        target.top_padding    = sm.top_padding
        target.bottom_padding = sm.bottom_padding
        target.left_padding   = sm.left_padding
        target.right_padding  = sm.right_padding
        target.window_gap     = sm.window_gap
        target.auto_padding   = sm.auto_padding
        view_update(target)
    } else {
        target.layout = VIEW_FLOAT
    }

    return target
}

/// `view_clear`
func view_clear(_ target: View)
{
    target.insertion_point = 0
    tree_view_clear(target)
    view_update(target)
}

/// `view_destroy`: releases the name of the space.
func view_destroy(_ target: View)
{
    tree_view_clear(target)

    target.uuid = nil
}
