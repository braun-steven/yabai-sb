import AppKit
import CPrivate
import CoreGraphics
import Logging
import YabaiCore

//
// NOTE: The space layout keeps a number of user spaces per display, chosen by the number of displays. When the
// displays change, reconcile passes move, create or destroy one space each until the counts match.
//

/// What a reconcile pass did (of the space layout or of the space pins): nothing left to do, one step, or a step that
/// failed.
enum ReconcileResult: Sendable {
  case done
  case performed
  case failed
}

/// The space properties used to decide the next layout reconcile step. Window-server queries are resolved before the
/// planner is called, so its choice is deterministic and can be tested without a live display.
struct SpaceLayoutSpaceState: Sendable {
  var sid: SpaceID
  var isUser: Bool
  var isLastUserSpace: Bool
}

struct SpaceLayoutDisplayState: Sendable {
  var did: DisplayID
  var spaces: [SpaceLayoutSpaceState]
  var visible: SpaceID?
}

enum SpaceLayoutReconcileAction: Equatable, Sendable {
  case done
  case move(space: SpaceID, from: DisplayID, to: DisplayID)
  case create(on: DisplayID)
  case destroy(space: SpaceID, on: DisplayID)
}

/// Plans one space layout reconcile step from a snapshot of display and space state.
enum SpaceLayoutReconciler {
  static func nextAction(
    target: [Int], displays: [SpaceLayoutDisplayState], pinned: Set<SpaceID>,
    emptySpaces: Set<SpaceID>
  ) -> SpaceLayoutReconcileAction {
    guard !displays.isEmpty, target.count == displays.count else { return .done }

    let actual = displays.map { $0.spaces.filter(\.isUser).count }
    let surplus = actual.indices.first { actual[$0] > target[$0] }
    let deficit = actual.indices.first { actual[$0] < target[$0] }

    switch (surplus, deficit) {
    case (let surplus?, let deficit?):
      let display = displays[surplus]
      let sid = SpaceLayout.moveCandidate(
        spaces: display.spaces.map(\.sid), user: display.spaces.map(\.isUser),
        visible: display.visible, fromEnd: deficit > surplus, pinned: pinned)

      if let sid {
        return .move(space: sid, from: display.did, to: displays[deficit].did)
      }

      return .create(on: displays[deficit].did)
    case (nil, let deficit?):
      return .create(on: displays[deficit].did)
    case (let surplus?, nil):
      let display = displays[surplus]
      guard
        let sid = destroyCandidate(
          on: display, pinned: pinned, emptySpaces: emptySpaces)
      else { return .done }

      return .destroy(space: sid, on: display.did)
    case (nil, nil):
      return .done
    }
  }

  /// Potential destroy candidates in the order the live pass should query them. It checks non-visible spaces first and
  /// puts the visible space last, matching the destroy preference without eagerly querying every space's windows.
  static func destroyCandidateOrder(
    on display: SpaceLayoutDisplayState, pinned: Set<SpaceID>
  ) -> [SpaceID] {
    let candidates = display.spaces.reversed().filter {
      $0.isUser && !$0.isLastUserSpace && !pinned.contains($0.sid)
    }
    let nonVisible = candidates.filter { $0.sid != display.visible }.map(\.sid)
    let visible = candidates.first(where: { $0.sid == display.visible }).map { [$0.sid] } ?? []
    return nonVisible + visible
  }

  private static func destroyCandidate(
    on display: SpaceLayoutDisplayState, pinned: Set<SpaceID>, emptySpaces: Set<SpaceID>
  ) -> SpaceID? {
    return destroyCandidateOrder(on: display, pinned: pinned).first { emptySpaces.contains($0) }
  }
}

extension SpaceManager {
  /// Performs one step that moves the user spaces towards the layout of the displays.
  func reconcileSpaceLayout() -> ReconcileResult {
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

    var spaceLists: [[SpaceID]] = []
    for did in didList {
      guard let spaces = did.spaces else { return .failed }
      spaceLists.append(spaces)
    }

    let userSpacesByDisplay = spaceLists.map { spaces in spaces.map(\.isUser) }
    let userCounts = userSpacesByDisplay.map { $0.filter { $0 }.count }
    let surplus = userCounts.indices.first { userCounts[$0] > target[$0] }
    let deficit = userCounts.indices.first { userCounts[$0] < target[$0] }

    //
    // NOTE: The pinned spaces (see SpacePinning.pinnedSpaces) are never moved or destroyed here. The pin reconcile moves
    // them to their displays, so a layout move of one would be undone by its pin, and the two would ping-pong.
    //
    let pinned = pinnedSpaces()

    let displayStates = didList.indices.map { index in
      let spaces = spaceLists[index]
      let userCount = userCounts[index]
      return SpaceLayoutDisplayState(
        did: didList[index],
        spaces: spaces.enumerated().map { spaceIndex, sid in
          let isUser = userSpacesByDisplay[index][spaceIndex]
          return SpaceLayoutSpaceState(
            sid: sid, isUser: isUser, isLastUserSpace: isUser && userCount == 1)
        },
        visible: index == surplus ? didList[index].currentSpace : nil)
    }

    var emptySpaces: Set<SpaceID> = []
    if let surplus, deficit == nil {
      for sid in SpaceLayoutReconciler.destroyCandidateOrder(
        on: displayStates[surplus], pinned: pinned)
      {
        guard let windows = sid.windows(includingMinimized: true) else { continue }
        if windows.isEmpty {
          emptySpaces.insert(sid)
          break
        }
      }
    }

    let action = SpaceLayoutReconciler.nextAction(
      target: target, displays: displayStates, pinned: pinned, emptySpaces: emptySpaces)

    switch action {
    case .done:
      if let surplus, deficit == nil {
        Logger.spaces.debug(
          "display \(surplus + 1) has \(userCounts[surplus])/\(target[surplus]) spaces, but no empty space can be destroyed"
        )
      }
      return .done
    case .move(let sid, let from, let to):
      let fromIndex = didList.firstIndex(of: from)!
      let toIndex = didList.firstIndex(of: to)!
      Logger.spaces.debug(
        "move space \(Int64(bitPattern: sid.rawValue)) from display \(fromIndex + 1) to display \(toIndex + 1)"
      )
      do { try moveSpace(sid, toDisplay: to) } catch { return .failed }
    case .create(let did):
      let index = didList.firstIndex(of: did)!
      if let surplus {
        Logger.spaces.debug(
          "display \(surplus + 1) has only pinned spaces; create space on display \(index + 1) (\(userCounts[index])/\(target[index]))"
        )
      } else {
        Logger.spaces.debug(
          "create space on display \(index + 1) (\(userCounts[index])/\(target[index]))")
      }
      do { try addSpace(onDisplayOf: did.currentSpace) } catch { return .failed }
    case .destroy(let sid, let did):
      let index = didList.firstIndex(of: did)!
      Logger.spaces.debug(
        "destroy empty space \(Int64(bitPattern: sid.rawValue)) on display \(index + 1) (\(userCounts[index])/\(target[index]))"
      )
      do { try destroySpace(sid) } catch { return .failed }
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
