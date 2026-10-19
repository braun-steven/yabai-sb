import ApplicationServices
import CoreGraphics
import Foundation
import CPrivate
import YabaiCore

//
// NOTE: The spaces of yabai: the views of every space (a table from the space id to its view), their invalidation and
// refresh. The layout and padding commands of spaces are in SpaceManager+Layout.swift, the space operations in
// SpaceManager+Operations.swift and the space layout in SpaceManager+SpaceLayout.swift.
//

/// Why a space operation failed (`checkSpaceOperation` in MessageSpace.swift words the failures every space command shares).
enum SpaceOperationError: Error, Sendable
{
    case missingSource
    case missingDestination
    case invalidSource
    case invalidDestination
    case invalidType
    case sameSpace
    case sameDisplay
    case inMissionControl
    case scriptingAdditionFailed
}

@WM final class SpaceManager
{
    /// See the NOTE of `DisplayManager.shared`.
    static let shared = SpaceManager()

    var views: [SpaceID: View] = [:]
    var currentSpaceID: SpaceID?
    var lastSpaceID: SpaceID?
    var didBegin = false
    var labels = LabelList<SpaceID>()
    var spaceLayoutGeneration: UInt32 = 0
    var spaceLayoutPasses = 0

    /// The view of a space; before `begin()` only a known one, after it the view is created when the space is new.
    func queryView(for sid: SpaceID) -> View?
    {
        if didBegin { return view(for: sid) }

        return views[sid]
    }

    /// The view of a space; it is created when the space is new.
    @discardableResult
    func view(for sid: SpaceID) -> View
    {
        if let found = views[sid] { return found }

        let created = View.create(sid: sid)
        views[sid] = created
        return created
    }

    func refreshView(for sid: SpaceID)
    {
        let target = view(for: sid)
        if target.layout == .float { return }

        target.updateAndFlush()
    }

    func markViewInvalid(for sid: SpaceID)
    {
        let target = view(for: sid)
        if target.layout == .float { return }

        target.isValid = false
    }

    func markSpacesInvalid(on did: DisplayID)
    {
        guard let spaceList = did.spaces else { return }

        let sid = did.currentSpace
        for space in spaceList {
            if space == sid, let sid {
                refreshView(for: sid)
            } else {
                markViewInvalid(for: space)
            }
        }
    }

    func markSpacesInvalid()
    {
        for did in DisplayID.all {
            markSpacesInvalid(on: did)
        }
    }

    func refreshApplicationWindows() -> Bool
    {
        let wm = WindowManager.shared

        var refreshCount = wm.applicationRefreshCount
        if refreshCount == 0 { return false }

        let windowCount = wm.window.count
        var i = 0
        while i < refreshCount {
            let application = wm.applicationRefresh(at: i)
            debug("SpaceManager.refreshApplicationWindows: \(application.name) has windows that are not yet resolved\n")

            if wm.addExistingApplicationWindows(application, refreshIndex: i) {
                refreshCount -= 1
                i -= 1
            }

            i += 1
        }

        return windowCount != wm.window.count
    }

    /// The views of the spaces of a new display keep their names, and take the new ids.
    func handleDisplayAdd(_ did: DisplayID)
    {
        guard let spaceList = did.spaces else { return }

        var viewList: [View?] = views.values.sorted(by: { $0.sid < $1.sid }).map { Optional($0) }
        var uuidList: [CFString?] = viewList.map { $0?.uuid }

        for sid in spaceList {
            guard let uuid = SLS.spaceNameObject(SLS.connection, sid) else { continue }

            for j in 0..<viewList.count {
                guard let viewUUID = uuidList[j], let target = viewList[j] else { continue }
                if !CFEqual(viewUUID, uuid) { continue }

                uuidList[j] = nil
                viewList[j] = nil

                views.removeValue(forKey: target.sid)

                labels.replace(id: target.sid, with: sid)

                target.sid = sid
                target.uuid = uuid

                if views[sid] == nil { views[sid] = target }
                break
            }
        }

        currentSpaceID = SpaceID.active
        lastSpaceID = currentSpaceID
    }

    /// The defaults of the space manager and an empty table of views.
    func resetToDefaults()
    {
        Config.current.space.layout = .tree
        Config.current.space.autoPadding = false
        Config.current.space.treeDefaultOrientation = .auto
        Config.current.space.treeWorkspaceTabbed = false
        Config.current.space.treeAutotiling = false
        labels = LabelList<SpaceID>()
        Config.current.space.skipWindowFocusAnimation = false
        //
        // NOTE: The views are keyed by space id.
        //

        views = [:]
    }

    /// Creates the views of every space of every display.
    func begin()
    {
        resetToDefaults()

        for did in DisplayID.all {
            guard let spaceList = did.spaces else { continue }

            for sid in spaceList {
                let created = View.create(sid: sid)
                if views[sid] == nil { views[sid] = created }
            }
        }

        currentSpaceID = SpaceID.active
        lastSpaceID = currentSpaceID
        didBegin = true
    }
}

extension ViewSpacing
{
    /// The default of the space manager, for the views without their own value.
    @WM var spaceManager: WritableKeyPath<SpaceDefaults, Int>
    {
        switch self {
        case .topPadding:    \.topPadding
        case .bottomPadding: \.bottomPadding
        case .leftPadding:   \.leftPadding
        case .rightPadding:  \.rightPadding
        case .windowGap:     \.windowGap
        }
    }
}
