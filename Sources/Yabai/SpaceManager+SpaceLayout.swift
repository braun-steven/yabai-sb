import AppKit
import CPrivate
import CoreGraphics
import Logging
import YabaiCore

//
// NOTE: The space layout keeps a number of user spaces per display, chosen by the number of displays. When the
// displays change, reconcile passes move, create or destroy one space each until the counts match.
//

/// What a reconcile pass did: nothing left to do, one step, or a step that failed.
enum SpaceLayoutResult: Sendable {
  case done
  case performed
  case failed
}

extension SpaceManager {
  private func userSpaceCount(_ spaces: [SpaceID]) -> Int {
    return spaces.filter { $0.isUser }.count
  }

  /// An empty user space of the display to destroy, preferring one that is not visible.
  private func destroyCandidate(on did: DisplayID) -> SpaceID? {
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

  /// Performs one step that moves the user spaces towards the layout of the displays.
  func reconcileSpaceLayout() -> SpaceLayoutResult {
    //
    // NOTE: Each pass reads the lists again: the previous pass may have changed them, and the next one decides on them.
    //
    DisplayManager.shared.invalidateSpaceCaches()

    let displayCount = DisplayID.count
    if displayCount < 1 || displayCount > SpaceLayout.max { return .done }

    guard let layout = Config.current.space.spaceLayouts.first(where: { $0.count == displayCount })
    else {
      Logger.spaces.debug("no space_layout for \(displayCount) display(s)")
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
      actual.append(userSpaceCount(spaces))
    }

    let surplus = (0..<displayCount).first { actual[$0] > target[$0] }
    let deficit = (0..<displayCount).first { actual[$0] < target[$0] }

    switch (surplus, deficit) {
    case (let surplus?, let deficit?):
      guard let spaces = didList[surplus].spaces else { return .failed }

      let user = spaces.map { $0.isUser }
      let sid = SpaceLayout.moveCandidate(
        spaces: spaces, user: user, visible: didList[surplus].currentSpace,
        fromEnd: deficit > surplus)

      Logger.spaces.debug(
        "move space \(Int64(bitPattern: sid?.rawValue ?? 0)) from display \(surplus + 1) to display \(deficit + 1)"
      )
      do { try moveSpace(sid, toDisplay: didList[deficit]) } catch { return .failed }
    case (nil, let deficit?):
      Logger.spaces.debug(
        "create space on display \(deficit + 1) (\(actual[deficit])/\(target[deficit]))")
      do { try addSpace(onDisplayOf: didList[deficit].currentSpace) } catch { return .failed }
    case (let surplus?, nil):
      guard let sid = destroyCandidate(on: didList[surplus]) else {
        Logger.spaces.debug(
          "display \(surplus + 1) has \(actual[surplus])/\(target[surplus]) spaces, but no empty space can be destroyed"
        )
        return .done
      }

      Logger.spaces.debug(
        "destroy empty space \(Int64(bitPattern: sid.rawValue)) on display \(surplus + 1) (\(actual[surplus])/\(target[surplus]))"
      )
      do { try destroySpace(sid) } catch { return .failed }
    case (nil, nil):
      return .done
    }

    return .performed
  }

  //
  // NOTE: A schedule replaces the pending one: the keyed reconcile event supersedes the event still waiting in the
  // delayed queue. resetPasses restarts the limit of passes for a new change of the displays.
  //

  /// Posts the space layout reconcile event after the delay, superseding the pending one.
  func scheduleSpaceLayout(after delay: Duration, resetPasses: Bool) {
    if Config.current.space.spaceLayouts.isEmpty { return }
    if resetPasses { spaceLayoutPasses = 0 }

    EventLoop.post(.spaceLayoutReconcile, after: delay, key: .spaceLayoutReconcile)
  }
}
