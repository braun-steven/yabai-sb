import CoreGraphics
import Foundation
import CPrivate
import YabaiCore

//
// NOTE: A view is the layout state of one space: its tree, its area and its padding and gap. Ported from src/view.c.
//

/// The layout of a space, named as in `config layout` and `query --spaces`. A view of the default type follows the
/// global layout.
enum ViewType: String, CaseIterable, Sendable
{
    case `default`
    case float
    case tree
}

/// The settings a space set for itself with `config --space`: the global config no longer changes them for its view.
struct ViewOverrides: OptionSet, Sendable
{
    let rawValue: UInt32

    static let layout        = ViewOverrides(rawValue: 1 << 0)
    static let topPadding    = ViewOverrides(rawValue: 1 << 1)
    static let bottomPadding = ViewOverrides(rawValue: 1 << 2)
    static let leftPadding   = ViewOverrides(rawValue: 1 << 3)
    static let rightPadding  = ViewOverrides(rawValue: 1 << 4)
    static let windowGap     = ViewOverrides(rawValue: 1 << 5)
    static let autoPadding   = ViewOverrides(rawValue: 1 << 6)
}

/// A padding or the gap of a view, and of the space manager defaults that views without their own value follow.
enum ViewSpacing: CaseIterable, Sendable
{
    case topPadding
    case bottomPadding
    case leftPadding
    case rightPadding
    case windowGap

    /// The value in a view.
    var view: ReferenceWritableKeyPath<View, Int>
    {
        switch self {
        case .topPadding:    \.top_padding
        case .bottomPadding: \.bottom_padding
        case .leftPadding:   \.left_padding
        case .rightPadding:  \.right_padding
        case .windowGap:     \.window_gap
        }
    }

    /// The override a view records once it has its own value.
    var override: ViewOverrides
    {
        switch self {
        case .topPadding:    .topPadding
        case .bottomPadding: .bottomPadding
        case .leftPadding:   .leftPadding
        case .rightPadding:  .rightPadding
        case .windowGap:     .windowGap
        }
    }
}

/// `struct view`. isValid is false once the area of the view must be recomputed, isDirty while its tree has not been
/// laid out since it changed, and isUnpadded while auto padding removes its padding.
final class View
{
    var uuid: CFString?
    var sid: SpaceID = 0
    var area = Area.zero
    var tree: Con!
    var insertion_point: WindowID = 0
    var layout = ViewType.default
    var top_padding: Int = 0
    var bottom_padding: Int = 0
    var left_padding: Int = 0
    var right_padding: Int = 0
    var window_gap: Int = 0
    var auto_padding = false
    var overrides: ViewOverrides = []
    var isPaddingEnabled = false
    var isGapEnabled = false
    var isValid = false
    var isDirty = false
    var isUnpadded = false
}

extension View: Equatable
{
    static func == (a: View, b: View) -> Bool { a === b }
}

/// `view_window_gap`
func view_window_gap(_ target: View) -> Int
{
    return ViewArea.windowGap(gapEnabled: target.isGapEnabled, windowGap: target.window_gap)
}

/// `view_add_window`
func view_add_window(_ target: View, _ win: Window, _ insertionPoint: WindowID)
{
    tree_add_window(target, win, insertionPoint)
    if !view_update_auto_padding(target) { tree_view_update(target) }
    target.isDirty = true
}

/// `view_remove_window`
@discardableResult
func view_remove_window(_ target: View, _ win: Window) -> Bool
{
    if !tree_remove_window(target, win) { return false }

    if !view_update_auto_padding(target) { tree_view_update(target) }
    target.isDirty = true
    return true
}

/// `view_find_window_list`
func view_find_window_list(_ target: View) -> [WindowID]
{
    return treeViewWindowList(target)
}

/// `view_is_invalid`
func view_is_invalid(_ target: View) -> Bool
{
    return !target.isValid
}

/// `view_is_dirty`
func view_is_dirty(_ target: View) -> Bool
{
    return target.isDirty
}

/// `view_flush`: lays out the tree when the space is visible, otherwise keeps the view dirty until it is.
func view_flush(_ target: View)
{
    if space_is_visible(target.sid) {
        tree_flush(target)
        target.isDirty = false
    } else {
        target.isDirty = true
    }
}

/// `view_auto_padding_applies`
func view_auto_padding_applies(_ layout: ViewType, _ autoPadding: Bool, _ tiledCount: Int) -> Bool
{
    return ViewArea.autoPaddingApplies(isTree: layout == .tree, autoPadding: autoPadding, tiledCount: tiledCount)
}

/// `view_tiled_count`
func view_tiled_count(_ target: View) -> Int
{
    return tree_view_tiled_count(target)
}

/// `view_root_area`: the area of the windows of a view inside the frame of its display.
func view_root_area(_ target: View, _ frame: CGRect) -> Area
{
    let root = ViewArea.rootArea(Area(frame),
                                 paddingEnabled: target.isPaddingEnabled,
                                 unpadded: target.isUnpadded,
                                 top: target.top_padding,
                                 bottom: target.bottom_padding,
                                 left: target.left_padding,
                                 right: target.right_padding)

    return Area(x: root.x, y: root.y, w: root.w, h: root.h)
}

/// `view_update_with_auto_padding`
private func view_update_with_auto_padding(_ target: View, _ unpadded: Bool)
{
    target.isUnpadded = unpadded

    let did = space_display_id(target.sid)
    let frame = display_bounds_constrained(did, false)
    target.area = view_root_area(target, frame)

    tree_view_update(target)
    target.isValid = true
    target.isDirty = true
}

//
// NOTE: Re-layout the view if the tiled window count crossed the auto_padding threshold.
// Returns true if it did, in which case the whole tree must be flushed.
//

/// `view_update_auto_padding`
func view_update_auto_padding(_ target: View) -> Bool
{
    let unpadded = view_auto_padding_applies(target.layout, target.auto_padding, view_tiled_count(target))
    if unpadded == target.isUnpadded { return false }

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
func view_create(_ sid: SpaceID) -> View
{
    let target = View()

    target.sid = sid
    target.uuid = SLS.spaceNameObject(connection_global(), sid)
    target.isPaddingEnabled = true
    target.isGapEnabled = true

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
        target.layout = .float
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
