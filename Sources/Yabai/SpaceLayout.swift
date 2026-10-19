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
    return spaces.filter { $0.isUser }.count
}

/// `space_layout_destroy_candidate`: an empty user space of the display to destroy, preferring one that is not visible.
private func spaceLayoutDestroyCandidate(_ did: DisplayID) -> SpaceID?
{
    guard let spaces = did.spaces else { return nil }

    let visibleSid = did.currentSpace
    var fallbackSid: SpaceID? = nil

    for sid in spaces.reversed() {
        if !sid.isUser { continue }
        if sid.isLastUserSpace { continue }

        guard let windows = sid.windows(includingMinimized: true), windows.isEmpty else { continue }

        if sid != visibleSid { return sid }
        if fallbackSid == nil { fallbackSid = sid }
    }

    return fallbackSid
}

/// `space_layout_reconcile`: performs one step that moves the user spaces towards the layout of the displays.
func space_layout_reconcile(_ sm: SpaceManager) -> SpaceLayoutResult
{
    let displayCount = DisplayID.count
    if displayCount < 1 || displayCount > SpaceLayout.max { return .done }

    guard let layout = sm.spaceLayouts.first(where: { $0.count == displayCount }) else {
        debug("space_layout_reconcile: no space_layout for \(displayCount) display(s)\n")
        return .done
    }

    var didList: [DisplayID] = []
    var builtin: Int?

    for i in 0..<displayCount {
        guard let did = DisplayID(arrangement: i + 1) else { return .failed }

        didList.append(did)
        if builtin == nil && CGDisplayIsBuiltin(did.rawValue) != 0 { builtin = i }
    }

    let target = layout.targets(builtin: builtin)

    var actual: [Int] = []
    for did in didList {
        guard let spaces = did.spaces else { return .failed }
        actual.append(spaceLayoutUserSpaceCount(spaces))
    }

    let surplus = (0..<displayCount).first { actual[$0] > target[$0] }
    let deficit = (0..<displayCount).first { actual[$0] < target[$0] }

    let result: SpaceOperationResult

    switch (surplus, deficit) {
    case (let surplus?, let deficit?):
        guard let spaces = didList[surplus].spaces else { return .failed }

        let user = spaces.map { $0.isUser }
        let sid = SpaceLayout.moveCandidate(spaces: spaces, user: user, visible: didList[surplus].currentSpace, fromEnd: deficit > surplus)

        debug("space_layout_reconcile: move space \(Int64(bitPattern: sid?.rawValue ?? 0)) from display \(surplus + 1) to display \(deficit + 1)\n")
        result = space_manager_move_space_to_display(sm, sid, didList[deficit])
    case (nil, let deficit?):
        debug("space_layout_reconcile: create space on display \(deficit + 1) (\(actual[deficit])/\(target[deficit]))\n")
        result = space_manager_add_space(didList[deficit].currentSpace)
    case (let surplus?, nil):
        guard let sid = spaceLayoutDestroyCandidate(didList[surplus]) else {
            debug("space_layout_reconcile: display \(surplus + 1) has \(actual[surplus])/\(target[surplus]) spaces, but no empty space can be destroyed\n")
            return .done
        }

        debug("space_layout_reconcile: destroy empty space \(Int64(bitPattern: sid.rawValue)) on display \(surplus + 1) (\(actual[surplus])/\(target[surplus]))\n")
        result = space_manager_destroy_space(sid)
    case (nil, nil):
        return .done
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
    let sm = SpaceManager.shared

    if sm.spaceLayouts.isEmpty { return }
    if resetPasses { sm.spaceLayoutPasses = 0 }

    sm.spaceLayoutGeneration &+= 1
    let generation = sm.spaceLayoutGeneration

    DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
        EventLoop.post(.spaceLayoutReconcile(generation: generation))
    }
}
