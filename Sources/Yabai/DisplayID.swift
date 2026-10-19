import CoreGraphics
import CoreFoundation
import CPrivate
import Foundation
import YabaiCore

//
// NOTE: The displays as the window server describes them: their uuid, bounds, spaces and arrangement index.
//

extension DisplayID
{
    /// The display of a uuid string; nil when the window server does not know the uuid.
    init?(uuid: String)
    {
        guard let uuidRef = CFUUIDCreateFromString(nil, uuid as CFString) else { return nil }
        self.init(nonzero: CGDisplayGetDisplayIDFromUUID(uuidRef))
    }

    /// The display at an arrangement index (1-based); nil when there is none.
    @WM init?(arrangement: Int)
    {
        guard let uuid = DisplayManager.shared.arrangedDisplayUUID(arrangement) else { return nil }
        self.init(uuid: uuid)
    }

    /// The display under a point; nil when the window server knows none.
    init?(containing point: CGPoint)
    {
        guard let uuid = SLS.bestManagedDisplay(SLS.connection, forPoint: point) else { return nil }
        self.init(uuid: uuid)
    }

    /// The uuid as a CFString.
    var uuidObject: CFString?
    {
        guard let uuidRef = CGDisplayCreateUUIDFromDisplayID(rawValue) else { return nil }
        return CFUUIDCreateString(nil, uuidRef)
    }

    /// The uuid as a Swift string.
    var uuid: String?
    {
        return uuidObject as String?
    }

    /// The area of the display that windows can use, without the menu bar, the Dock and, unless ignored, the external bar.
    @WM func constrainedBounds(ignoringExternalBar: Bool) -> CGRect
    {
        let dm = DisplayManager.shared
        let externalBar = Config.current.display.externalBar
        var frame = CGDisplayBounds(rawValue)
        var effectiveExtTopPadding: Int = 0

        if !ignoringExternalBar {
            if (externalBar.mode == .main && self == DisplayID.main) ||
               (externalBar.mode == .all) {
                effectiveExtTopPadding = externalBar.topPadding

                frame.origin.y    += CGFloat(effectiveExtTopPadding)
                frame.size.height -= CGFloat(effectiveExtTopPadding)
                frame.size.height -= CGFloat(externalBar.bottomPadding)
            }
        }

        if dm.isMenuBarHidden {
            let notchHeight = self.notchHeight
            if notchHeight > effectiveExtTopPadding {
                frame.origin.y    += CGFloat(notchHeight - effectiveExtTopPadding)
                frame.size.height -= CGFloat(notchHeight - effectiveExtTopPadding)
            }
        } else {
            let menu = menuBarRect
            frame.origin.y    += menu.size.height
            frame.size.height -= menu.size.height
        }

        if !dm.isDockHidden {
            if self == DisplayID.dock {
                let dock = dm.dockRect
                switch dm.dockOrientation {
                case .left:
                    frame.origin.x   += dock.size.width
                    frame.size.width -= dock.size.width
                case .right:
                    frame.size.width -= dock.size.width
                case .bottom:
                    frame.size.height -= dock.size.height
                case nil: break
                }
            }
        }

        return frame
    }

    /// The center of the display; the zero point for an invalid display, as CGDisplayBounds gives it.
    var center: CGPoint
    {
        let bounds = CGDisplayBounds(rawValue)
        return CGPoint(x: bounds.origin.x + bounds.size.width/2, y: bounds.origin.y + bounds.size.height/2)
    }

    /// The space the window server shows on the display; nil when it reports none.
    var currentSpace: SpaceID?
    {
        guard let uuid = self.uuid else { return nil }
        return SLS.currentSpace(SLS.connection, forDisplay: uuid)
    }

    /// The spaces of the display in the order of the window server; nil when the display or the window server does not
    /// know it.
    var spaces: [SpaceID]?
    {
        guard let uuid = self.uuid else { return nil }

        var result: [SpaceID]?
        for display in SLS.managedDisplaySpaces(SLS.connection) {
            guard let identifier = display["Display Identifier"] as? String, identifier.utf8.elementsEqual(uuid.utf8) else { continue }

            let spaceList = display["Spaces"] as? [NSDictionary] ?? []
            result = spaceList.compactMap { space in (space["id64"] as? NSNumber).flatMap { SpaceID(nonzero: $0.uint64Value) } }
        }

        return result
    }

    /// The arrangement index of the display (1-based); 0 when the window server does not arrange it.
    @WM var arrangement: Int
    {
        guard let uuid = self.uuid else { return 0 }
        guard let displays = DisplayManager.shared.arrangedDisplays else { return 0 }
        guard let index = displays.firstIndex(where: { $0.utf8.elementsEqual(uuid.utf8) }) else { return 0 }

        return index + 1
    }

    /// The display before this one in the arrangement.
    @WM var previous: DisplayID?
    {
        let arrangement = self.arrangement
        if arrangement <= 1 { return nil }

        return DisplayID(arrangement: arrangement - 1)
    }

    /// The display after this one in the arrangement.
    @WM var next: DisplayID?
    {
        let arrangement = self.arrangement
        if arrangement >= DisplayID.count { return nil }

        return DisplayID(arrangement: arrangement + 1)
    }

    /// The first display in the arrangement.
    @WM static var first: DisplayID?
    {
        return DisplayID(arrangement: 1)
    }

    /// The last display in the arrangement.
    @WM static var last: DisplayID?
    {
        let arrangement = DisplayID.count
        return DisplayID(arrangement: arrangement)
    }

    /// The nearest display in a direction, nil if there is none.
    func closestDisplay(in direction: Direction) -> DisplayID?
    {
        var bestDid: DisplayID? = nil
        var bestDistance = Int.max

        let sourceArea = Area(CGDisplayBounds(rawValue))
        let sourceAreaMax = sourceArea.maxPoint

        for did in DisplayID.all {
            if did == self { continue }

            let targetArea = Area(CGDisplayBounds(did.rawValue))
            let targetAreaMax = targetArea.maxPoint

            if Area.isInDirection(sourceArea, sourceAreaMax, targetArea, targetAreaMax, direction) {
                let distance = Area.distanceInDirection(sourceArea, sourceAreaMax, targetArea, targetAreaMax, direction)
                if distance < bestDistance {
                    bestDid = did
                    bestDistance = distance
                }
            }
        }

        return bestDid
    }

    /// The menu bar of the display: its bounds with the height of the menu bar.
    var menuBarRect: CGRect
    {
        //
        // NOTE(asmvik): SLSGetRevealedMenuBarBounds is broken on Apple Silicon,
        // but we expected it to return the full display bounds along with the menubar
        // height. Combine this information ourselves using two separate functions..
        //

        var bounds = CGDisplayBounds(rawValue)
        bounds.size.height = CGFloat(SLS.displayMenuBarHeight(self))

        //
        // NOTE(asmvik): Height needs to be offset by 1 because that is the actual
        // position on the screen that windows can be positioned at..
        //

        bounds.size.height += 1
        return bounds
    }

    /// The main display.
    static var main: DisplayID
    {
        return DisplayID(CGMainDisplayID())
    }

    /// The display of the active menu bar; nil when the window server names no active display.
    static var active: DisplayID?
    {
        let uuid = SLS.activeMenuBarDisplay(SLS.connection)
        assert(uuid != nil)

        return uuid.flatMap { DisplayID(uuid: $0) }
    }

    /// The display holding the Dock; nil when the window server names none.
    @WM static var dock: DisplayID?
    {
        guard let uuid = SLS.bestManagedDisplay(SLS.connection, forRect: DisplayManager.shared.dockRect) else { return nil }
        return DisplayID(uuid: uuid)
    }

    /// The display under the cursor.
    static var underCursor: DisplayID?
    {
        return DisplayID(containing: SLS.cursorLocation(SLS.connection))
    }

    /// The number of active displays.
    static var count: Int
    {
        var activeCount: UInt32 = 0
        CGGetActiveDisplayList(0, nil, &activeCount)
        return Int(activeCount)
    }

    /// The active displays, in the order the window server lists them.
    static var all: [DisplayID]
    {
        let displayCount = DisplayID.count

        var displays = [UInt32](repeating: 0, count: displayCount)
        var actual: UInt32 = 0
        CGGetActiveDisplayList(UInt32(displayCount), &displays, &actual)

        return displays.prefix(Int(actual)).map { DisplayID($0) }
    }

    /// Makes the display the active one of the menu bar.
    func activate()
    {
        guard let uuid = self.uuid else { return }
        SLS.setActiveMenuBarDisplay(SLS.connection, uuid)
    }

    /// Focuses the display, through its frontmost window on the space, or its cursor.
    @WM func focus(space: SpaceID?)
    {
        let wm = WindowManager.shared

        if let sid = space, let window = wm.window(on: sid, byRank: 1, excluding: nil) {
            WindowManager.shared.focusWithRaise(window)
            wm.centerMouse(on: window)
            activate()
        } else {
            let point = center
            CGWarpMouseCursorPosition(point)
            activate()

            if SpaceID.active != currentSpace {
                CGPostMouseEventC(point, false, true)
                CGPostMouseEventC(point, false, false)
            }
        }
    }

    /// Focuses a space of the display through the scripting addition.
    func focusSpace(_ sid: SpaceID) throws(SpaceOperationError)
    {
        if MissionControl.shared.isActive { throw .inMissionControl }

        let spaceDid = sid.display
        if spaceDid != self { throw .sameDisplay }

        if !ScriptingAddition.shared.focusSpace(sid) { throw .scriptingAdditionFailed }
    }
}
