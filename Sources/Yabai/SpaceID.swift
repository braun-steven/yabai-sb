import CoreGraphics
import Foundation
import CPrivate
import YabaiCore

//
// NOTE: The spaces as the window server describes them: their display, their type, their order in Mission Control and
// the windows on them. The predicates that classify the windows of a query are in YabaiCore (SpaceWindow).
//

extension SpaceID
{
    /// The display of the space; nil when the window server does not know it.
    var display: DisplayID?
    {
        guard let uuid = SLS.managedDisplay(SLS.connection, forSpace: self) else { return nil }
        return DisplayID(uuid: uuid)
    }

    /// Every window the window server lists on the spaces (of the connection, or of every connection for 0), including
    /// the ones that are not user windows; nil when the window server fails.
    static func windowCandidates(on spaces: [SpaceID], connection cid: Int32, includingMinimized: Bool) -> [WindowID]?
    {
        let options: UInt32 = includingMinimized ? 0x7 : 0x2
        return SLS.windows(SLS.connection, owner: UInt32(bitPattern: cid), spaces: spaces, options: options)
    }

    /// The windows on the spaces; nil when the window server fails.
    static func windows(on spaces: [SpaceID], connection cid: Int32, includingMinimized: Bool) -> [WindowID]?
    {
        return windowCandidates(on: spaces, connection: cid, includingMinimized: includingMinimized).map { candidates in
            userWindows(among: candidates, includingMinimized: includingMinimized)
        }
    }

    /// The candidates that are windows of the user: the ones yabai knows (minimized ones only with includingMinimized) and
    /// the ones the window server describes as user windows.
    static func userWindows(among candidates: [WindowID], includingMinimized: Bool) -> [WindowID]
    {
        if candidates.isEmpty { return [] }

        var result: [WindowID] = []
        for window in SLS.queryWindows(SLS.connection, candidates) {
            let known = WindowManager.shared.window(for: window.id).map { target in
                includingMinimized || !target.isMinimized
            } ?? false

            if known ||
               SpaceWindow.isUserWindow(parentID: window.parent, level: window.level, tags: window.tags, attributes: window.attributes) ||
               (includingMinimized && SpaceWindow.isMinimizedUserWindow(parentID: window.parent, level: window.level, tags: window.tags, attributes: window.attributes)) {
                result.append(window.id)
            }
        }

        return result
    }

    /// The windows on the space; nil when the window server fails.
    func windows(includingMinimized: Bool) -> [WindowID]?
    {
        return SpaceID.windows(on: [self], connection: 0, includingMinimized: includingMinimized)
    }

    var isUser: Bool
    {
        return SLS.spaceType(SLS.connection, self) == 0
    }

    var isFullscreen: Bool
    {
        return SLS.spaceType(SLS.connection, self) == 4
    }

    /// The space is the one that its display shows.
    var isVisible: Bool
    {
        guard let did = display else { return false }
        return self == did.currentSpace
    }

    /// Every space in the order Mission Control numbers them, display by display.
    static var all: [SpaceID]
    {
        var result: [SpaceID] = []

        for display in DisplayManager.shared.managedDisplaySpaces {
            guard let spaces = display["Spaces"] as? [NSDictionary] else { continue }

            for space in spaces {
                guard let sid = (space["id64"] as? NSNumber).flatMap({ SpaceID(nonzero: $0.uint64Value) }) else { continue }
                result.append(sid)
            }
        }

        return result
    }

    /// The Mission Control number of the space, or 0.
    var missionControlIndex: Int
    {
        return (SpaceList.indexOf(spaces: SpaceID.all, sid: self) ?? -1) + 1
    }

    /// The space with the Mission Control number, or nil.
    init?(missionControlIndex desktopID: Int)
    {
        let spaces = SpaceID.all
        guard desktopID >= 1 && desktopID <= spaces.count else { return nil }

        self = spaces[desktopID - 1]
    }

    /// The space shown on the display under the cursor.
    static var underCursor: SpaceID?
    {
        return DisplayID.underCursor.flatMap { $0.currentSpace }
    }

    var previous: SpaceID?
    {
        return SpaceList.neighbour(spaces: SpaceID.all, sid: self, offset: -1)
    }

    var next: SpaceID?
    {
        return SpaceList.neighbour(spaces: SpaceID.all, sid: self, offset: 1)
    }

    /// The focused window, or the one that the known focus names when it is still valid.
    private static var focusedWindow: Window?
    {
        let front = SLS.frontProcess()

        let wm = WindowManager.shared
        let pendingFocus = pendingWindowFocus.load(ordering: .acquiring)

        if wm.canUseKnownFocus(front: front, pendingFocus: pendingFocus) {
            if let focusedID = wm.focusedWindowID, let target = wm.window(for: focusedID) { return target }
        }

        return wm.focusedWindow
    }

    /// The space of the focused window, or of the active display; nil when neither is known.
    static var active: SpaceID?
    {
        var did: DisplayID? = nil
        let focused = focusedWindow

        if let focused { did = focused.id.displayID }
        if did == nil { did = DisplayID.active }

        return did.flatMap { $0.currentSpace }
    }

    func moveWindows(_ windows: [WindowID])
    {
        if SLS.hasBridgedWindowOperation {
            SLS.bridgedMoveWindows(windows, toSpace: self)
        } else if !ScriptingAddition.shared.moveWindows(windows, to: self) {
            SLSSpaceSetCompatID(SLS.connection, self.rawValue, 0x79616265)
            var rawWindows = windows.map(\.rawValue)
            SLSSetWindowListWorkspace(SLS.connection, &rawWindows, Int32(rawWindows.count), 0x79616265)
            SLSSpaceSetCompatID(SLS.connection, self.rawValue, 0x0)
        }
    }

    func moveWindow(_ win: Window)
    {
        if SLS.hasBridgedWindowOperation {
            SLS.bridgedMoveWindows([win.id], toSpace: self)
        } else if !ScriptingAddition.shared.moveWindow(win.id, to: self) {
            var windows = [win.id.rawValue]
            SLSSpaceSetCompatID(SLS.connection, self.rawValue, 0x79616265)
            SLSSetWindowListWorkspace(SLS.connection, &windows, 1, 0x79616265)
            SLSSpaceSetCompatID(SLS.connection, self.rawValue, 0x0)
        }
    }

    //
    // NOTE: The bridged operation moves windows asynchronously. Laying out or focusing a window before it has
    // arrived on its new space places it on the wrong display, or makes macOS switch to the space it came from.
    // The wait is bounded, because it blocks the event loop and a window may not be moved at all.
    //

    func waitForWindow(_ wid: WindowID, timeoutMS: Int) -> Bool
    {
        var i = 0
        while i < timeoutMS / 10 {
            if wid.space == self { return true }
            usleep(10000)
            i += 1
        }

        return wid.space == self
    }

    func waitForWindows(_ windows: [WindowID], timeoutMS: Int) -> Bool
    {
        var arrived = 0

        var i = 0
        while i < timeoutMS / 10 {
            while arrived < windows.count && windows[arrived].space == self { arrived += 1 }
            if arrived == windows.count { return true }

            usleep(10000)
            i += 1
        }

        while arrived < windows.count && windows[arrived].space == self { arrived += 1 }
        return arrived == windows.count
    }

    /// Whether no other user space is on the display of the space.
    var isLastUserSpace: Bool
    {
        guard let did = display, let spaces = did.spaces else { return true }

        for other in spaces {
            if self == other { continue }
            if other.isUser { return false }
        }

        return true
    }
}
