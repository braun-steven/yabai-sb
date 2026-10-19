import CoreGraphics
import Dispatch
import AppKit
import CPrivate
import YabaiCore

//
// NOTE: space_layout keeps a number of user spaces per display, chosen by the number of displays. When the
// displays change, reconcile passes move, create or destroy one space each until the counts match.
//

/// What a reconcile pass did: nothing left to do, one step, or a step that failed.
enum SpaceLayoutResult: Sendable
{
    case done
    case performed
    case failed
}

/// `space_layout_user_space_count`
private func spaceLayoutUserSpaceCount(_ spaces: [SpaceID]) -> Int
{
    return spaces.filter { space_is_user($0) }.count
}

/// `space_layout_destroy_candidate`: an empty user space of the display to destroy, preferring one that is not visible.
private func spaceLayoutDestroyCandidate(_ did: DisplayID) -> SpaceID
{
    guard let spaces = displaySpaces(did) else { return 0 }

    let visibleSid = display_space_id(did)
    var fallbackSid: SpaceID = 0

    for sid in spaces.reversed() {
        if !space_is_user(sid) { continue }
        if space_manager_is_space_last_user_space(sid) { continue }

        guard let windows = space_window_list(sid, true), windows.isEmpty else { continue }

        if sid != visibleSid { return sid }
        if fallbackSid == 0 { fallbackSid = sid }
    }

    return fallbackSid
}

/// `space_layout_reconcile`: performs one step that moves the user spaces towards the layout of the displays.
func space_layout_reconcile(_ sm: SpaceManager) -> SpaceLayoutResult
{
    let displayCount = display_manager_active_display_count()
    if displayCount < 1 || displayCount > SpaceLayout.max { return .done }

    guard let layout = sm.space_layouts.first(where: { $0.count == displayCount }) else {
        debug("space_layout_reconcile: no space_layout for \(displayCount) display(s)\n")
        return .done
    }

    var didList: [DisplayID] = []
    var builtin: Int?

    for i in 0..<displayCount {
        let did = display_manager_arrangement_display_id(i + 1)
        if did == 0 { return .failed }

        didList.append(did)
        if builtin == nil && CGDisplayIsBuiltin(did.rawValue) != 0 { builtin = i }
    }

    let target = layout.targets(builtin: builtin)

    var actual: [Int] = []
    for did in didList {
        guard let spaces = displaySpaces(did) else { return .failed }
        actual.append(spaceLayoutUserSpaceCount(spaces))
    }

    var surplus = -1
    var deficit = -1
    for i in 0..<displayCount {
        if surplus == -1 && actual[i] > target[i] { surplus = i }
        if deficit == -1 && actual[i] < target[i] { deficit = i }
    }

    if surplus == -1 && deficit == -1 { return .done }

    let result: SpaceOperationResult

    if surplus != -1 && deficit != -1 {
        guard let spaces = displaySpaces(didList[surplus]) else { return .failed }

        let user = spaceUserList(spaces)
        let sid = SpaceLayout.moveCandidate(spaces: spaces, user: user, visible: display_space_id(didList[surplus]), fromEnd: deficit > surplus)

        debug("space_layout_reconcile: move space \(Int64(bitPattern: sid.rawValue)) from display \(surplus + 1) to display \(deficit + 1)\n")
        result = space_manager_move_space_to_display(sm, sid, didList[deficit])
    } else if deficit != -1 {
        debug("space_layout_reconcile: create space on display \(deficit + 1) (\(actual[deficit])/\(target[deficit]))\n")
        result = space_manager_add_space(display_space_id(didList[deficit]))
    } else {
        let sid = spaceLayoutDestroyCandidate(didList[surplus])
        if sid == 0 {
            debug("space_layout_reconcile: display \(surplus + 1) has \(actual[surplus])/\(target[surplus]) spaces, but no empty space can be destroyed\n")
            return .done
        }

        debug("space_layout_reconcile: destroy empty space \(Int64(bitPattern: sid.rawValue)) on display \(surplus + 1) (\(actual[surplus])/\(target[surplus]))\n")
        result = space_manager_destroy_space(sid)
    }

    return result == .success ? .performed : .failed
}

//
// NOTE: A schedule replaces the pending one: SPACE_LAYOUT_RECONCILE only runs for the latest generation.
// reset_passes restarts the limit of passes for a new change of the displays.
//

/// `space_layout_schedule`: posts SPACE_LAYOUT_RECONCILE for the current generation after delay seconds.
func space_layout_schedule(_ delay: Double, _ resetPasses: Bool)
{
    let sm = space_manager_global()

    if sm.space_layouts.isEmpty { return }
    if resetPasses { sm.space_layout_passes = 0 }

    sm.space_layout_gen &+= 1
    let generation = sm.space_layout_gen

    DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
        EventLoop.post(.spaceLayoutReconcile(generation: generation))
    }
}
