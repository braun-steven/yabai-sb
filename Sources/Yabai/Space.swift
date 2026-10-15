import CoreGraphics
import Foundation
import YabaiC
import YabaiCore

//
// NOTE: The spaces as the window server describes them: their display, their type and the windows on them. Ported from
// src/space.c. The predicates that classify the windows of a query are in YabaiCore (SpaceWindow).
//

/// `space_display_id`
@_cdecl("space_display_id")
func space_display_id(_ sid: UInt64) -> UInt32
{
    guard let uuid = SLS.managedDisplay(connection_global(), forSpace: sid) else { return 0 }
    return displayID(uuid)
}

/// `space_window_list_for_connection`: the windows on the spaces, in temporary storage. count gets the number of windows.
/// nil when the window server fails (count is left alone), or when no window is on the spaces (count is 0).
@_cdecl("space_window_list_for_connection")
func space_window_list_for_connection(_ spaceList: UnsafeMutablePointer<UInt64>?, _ spaceCount: Int32, _ cid: Int32, _ count: UnsafeMutablePointer<Int32>, _ includeMinimized: Bool) -> UnsafeMutablePointer<UInt32>?
{
    let spaces = Array(UnsafeBufferPointer(start: spaceList, count: Int(spaceCount)))
    let options: UInt32 = includeMinimized ? 0x7 : 0x2

    guard let candidates = SLS.windows(connection_global(), owner: UInt32(bitPattern: cid), spaces: spaces, options: options) else { return nil }

    count.pointee = Int32(candidates.count)
    if candidates.isEmpty { return nil }

    var result: [UInt32] = []
    for window in SLS.queryWindows(connection_global(), candidates) {
        let known = window_manager_find_window(window_manager_global(), window.id).map { target in
            includeMinimized || !window_check_flag(target, WINDOW_MINIMIZE)
        } ?? false

        if known ||
           SpaceWindow.isUserWindow(parentID: window.parent, level: window.level, tags: window.tags, attributes: window.attributes) ||
           (includeMinimized && SpaceWindow.isMinimizedUserWindow(parentID: window.parent, level: window.level, tags: window.tags, attributes: window.attributes)) {
            result.append(window.id)
        }
    }

    count.pointee = Int32(result.count)
    return temporaryList(result)
}

/// `space_window_list`: the windows on one space, in temporary storage.
@_cdecl("space_window_list")
func space_window_list(_ sid: UInt64, _ count: UnsafeMutablePointer<Int32>, _ includeMinimized: Bool) -> UnsafeMutablePointer<UInt32>?
{
    var sid = sid
    return space_window_list_for_connection(&sid, 1, 0, count, includeMinimized)
}

/// `space_is_user`
@_cdecl("space_is_user")
func space_is_user(_ sid: UInt64) -> Bool
{
    return SLS.spaceType(connection_global(), sid) == 0
}

/// `space_is_fullscreen`
@_cdecl("space_is_fullscreen")
func space_is_fullscreen(_ sid: UInt64) -> Bool
{
    return SLS.spaceType(connection_global(), sid) == 4
}

/// `space_is_visible`: the space is the one that its display shows.
@_cdecl("space_is_visible")
func space_is_visible(_ sid: UInt64) -> Bool
{
    return sid == display_space_id(space_display_id(sid))
}

/// `space_window_is_user_window`, for the C callers that classify query results.
@_cdecl("space_window_is_user_window")
func space_window_is_user_window(_ parentWID: UInt32, _ level: Int32, _ tags: UInt64, _ attributes: UInt64) -> Bool
{
    return SpaceWindow.isUserWindow(parentID: parentWID, level: level, tags: tags, attributes: attributes)
}
