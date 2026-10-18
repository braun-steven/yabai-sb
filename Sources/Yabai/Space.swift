import CoreGraphics
import Foundation
import CPrivate
import YabaiCore

//
// NOTE: The spaces as the window server describes them: their display, their type and the windows on them. Ported from
// src/space.c. The predicates that classify the windows of a query are in YabaiCore (SpaceWindow).
//

/// `space_display_id`
func space_display_id(_ sid: SpaceID) -> DisplayID
{
    guard let uuid = SLS.managedDisplay(connection_global(), forSpace: sid) else { return 0 }
    return displayID(uuid)
}

/// `space_window_list_for_connection`: the windows on the spaces; count gets their number. nil when the window server
/// fails (count is left alone), or when no window is on the spaces (count is 0).
func space_window_list_for_connection(_ spaces: [SpaceID], _ cid: Int32, _ count: inout Int32, _ includeMinimized: Bool) -> [UInt32]?
{
    let options: UInt32 = includeMinimized ? 0x7 : 0x2

    guard let candidates = SLS.windows(connection_global(), owner: UInt32(bitPattern: cid), spaces: spaces, options: options) else { return nil }

    count = Int32(candidates.count)
    if candidates.isEmpty { return nil }

    var result: [UInt32] = []
    for window in SLS.queryWindows(connection_global(), candidates) {
        let known = window_manager_find_window(window_manager_global(), window.id).map { target in
            includeMinimized || !target.isMinimized
        } ?? false

        if known ||
           SpaceWindow.isUserWindow(parentID: window.parent, level: window.level, tags: window.tags, attributes: window.attributes) ||
           (includeMinimized && SpaceWindow.isMinimizedUserWindow(parentID: window.parent, level: window.level, tags: window.tags, attributes: window.attributes)) {
            result.append(window.id)
        }
    }

    count = Int32(result.count)
    return result
}

/// `space_window_list`: the windows on one space.
func space_window_list(_ sid: SpaceID, _ count: inout Int32, _ includeMinimized: Bool) -> [UInt32]?
{
    return space_window_list_for_connection([sid], 0, &count, includeMinimized)
}

/// `space_is_user`
func space_is_user(_ sid: SpaceID) -> Bool
{
    return SLS.spaceType(connection_global(), sid) == 0
}

/// `space_is_fullscreen`
func space_is_fullscreen(_ sid: SpaceID) -> Bool
{
    return SLS.spaceType(connection_global(), sid) == 4
}

/// `space_is_visible`: the space is the one that its display shows.
func space_is_visible(_ sid: SpaceID) -> Bool
{
    return sid == display_space_id(space_display_id(sid))
}
