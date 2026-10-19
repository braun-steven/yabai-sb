import CoreGraphics
import Foundation
import CPrivate
import YabaiCore

// NOTE: A view is the layout state of one space: its tree, its area and its padding and gap.

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
        case .topPadding:    \.topPadding
        case .bottomPadding: \.bottomPadding
        case .leftPadding:   \.leftPadding
        case .rightPadding:  \.rightPadding
        case .windowGap:     \.windowGap
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

/// isValid is false once the area of the view must be recomputed, isDirty while its tree has not been laid out since it
/// changed, and isUnpadded while auto padding removes its padding.
final class View
{
    var uuid: CFString?
    var sid: SpaceID
    var area = Area.zero
    var tree: Con?
    var insertionPoint: WindowID?
    var layout = ViewType.default
    var topPadding: Int = 0
    var bottomPadding: Int = 0
    var leftPadding: Int = 0
    var rightPadding: Int = 0
    var windowGap: Int = 0
    var autoPadding = false
    var overrides: ViewOverrides = []
    var isPaddingEnabled = false
    var isGapEnabled = false
    var isValid = false
    var isDirty = false
    var isUnpadded = false

    init(sid: SpaceID)
    {
        self.sid = sid
    }

    var windowGapValue: Int
    {
        ViewArea.windowGap(gapEnabled: isGapEnabled, windowGap: windowGap)
    }

    var isInvalid: Bool { !isValid }

    var windowIDs: [WindowID] { treeViewWindowList(self) }

    var tiledCount: Int { tree_view_tiled_count(self) }

    func add(_ window: Window, insertionPoint: WindowID?)
    {
        tree_add_window(self, window, insertionPoint)
        if !updateAutoPadding() { tree_view_update(self) }
        isDirty = true
    }

    @discardableResult
    func remove(_ window: Window) -> Bool
    {
        if !tree_remove_window(self, window) { return false }

        if !updateAutoPadding() { tree_view_update(self) }
        isDirty = true
        return true
    }

    func flush()
    {
        if space_is_visible(sid) {
            tree_flush(self)
            isDirty = false
        } else {
            isDirty = true
        }
    }

    func rootArea(in frame: CGRect) -> Area
    {
        let root = ViewArea.rootArea(Area(frame),
                                     paddingEnabled: isPaddingEnabled,
                                     unpadded: isUnpadded,
                                     top: topPadding,
                                     bottom: bottomPadding,
                                     left: leftPadding,
                                     right: rightPadding)

        return Area(x: root.x, y: root.y, w: root.w, h: root.h)
    }

    // NOTE: Re-layout the view if the tiled window count crossed the auto padding threshold. Returns true if it did,
    // in which case the whole tree must be flushed.
    @discardableResult
    func updateAutoPadding() -> Bool
    {
        let unpadded = Self.autoPaddingApplies(layout: layout, autoPadding: autoPadding, tiledCount: tiledCount)
        if unpadded == isUnpadded { return false }

        updateWithAutoPadding(unpadded)
        return true
    }

    func update()
    {
        updateWithAutoPadding(Self.autoPaddingApplies(layout: layout, autoPadding: autoPadding, tiledCount: tiledCount))
    }

    func updateAndFlush()
    {
        update()
        flush()
    }

    func clear()
    {
        insertionPoint = nil
        tree_view_clear(self)
        update()
    }

    func destroy()
    {
        tree_view_clear(self)
        uuid = nil
    }

    private func updateWithAutoPadding(_ unpadded: Bool)
    {
        isUnpadded = unpadded

        guard let did = space_display_id(sid) else { return }
        let frame = display_bounds_constrained(did, false)
        area = rootArea(in: frame)

        tree_view_update(self)
        isValid = true
        isDirty = true
    }

    static func autoPaddingApplies(layout: ViewType, autoPadding: Bool, tiledCount: Int) -> Bool
    {
        ViewArea.autoPaddingApplies(isTree: layout == .tree, autoPadding: autoPadding, tiledCount: tiledCount)
    }

    static func create(sid: SpaceID) -> View
    {
        let target = View(sid: sid)

        target.uuid = SLS.spaceNameObject(connection_global(), sid)
        target.isPaddingEnabled = true
        target.isGapEnabled = true

        if space_is_user(target.sid) {
            let sm = space_manager_global()

            target.layout         = sm.layout
            target.topPadding     = sm.top_padding
            target.bottomPadding  = sm.bottom_padding
            target.leftPadding    = sm.left_padding
            target.rightPadding   = sm.right_padding
            target.windowGap      = sm.window_gap
            target.autoPadding    = sm.auto_padding
            target.update()
        } else {
            target.layout = .float
        }

        return target
    }
}

extension View: Equatable
{
    static func == (a: View, b: View) -> Bool { a === b }
}
