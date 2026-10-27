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
    var arrangement: [String] = []
    var builtin: Int?

    for i in 0..<displayCount {
      guard let uuid = DisplayManager.shared.arrangedDisplayUUID(i + 1),
        let did = DisplayID(uuid: uuid)
      else { return .failed }

      didList.append(did)
      arrangement.append(uuid)
      if builtin == nil && CGDisplayIsBuiltin(did.rawValue) != 0 { builtin = i }
    }

    let target = layout.targets(builtin: builtin)

    var spaces: [[SpaceID]] = []
    for did in didList {
      guard let list = did.spaces else { return .failed }
      spaces.append(list)
    }
    let user = spaces.map { $0.map(\.isUser) }

    //
    // NOTE: The spaces whose display went away go back to it when it is connected again (SpaceHomes): the layout
    // takes them first for that display. The homes are recorded once the counts match, and by every space move.
    //
    var spaceUUID: [SpaceID: String] = [:]
    for (i, list) in spaces.enumerated() {
      for (j, sid) in list.enumerated() where user[i][j] {
        spaceUUID[sid] = SLS.spaceName(SLS.connection, sid)
      }
    }
    let home = spaceHomes.homeIndices(
      of: Array(spaceUUID.keys), spaceUUID: { spaceUUID[$0] }, arrangement: arrangement)

    //
    // NOTE: The pinned spaces (see SpacePinning.pinnedSpaces) are never moved or destroyed here. The pin reconcile moves
    // them to their displays, so a layout move of one would be undone by its pin, and the two would ping-pong.
    //
    let step = SpaceLayout.reconcileStep(
      target: target, spaces: spaces, user: user, pinned: pinnedSpaces(), home: home,
      visible: { didList[$0].currentSpace },
      isEmpty: { $0.windows(includingMinimized: true)?.isEmpty ?? false })

    /// The user spaces and the target of a display, for the log.
    func counts(_ i: Int) -> String { "\(user[i].count(where: { $0 }))/\(target[i])" }

    /// Records the display of every user space as its home, once the pass has nothing left to do.
    func recordHomes() {
      var located: [String: String] = [:]
      for (i, list) in spaces.enumerated() {
        for sid in list { if let uuid = spaceUUID[sid] { located[uuid] = arrangement[i] } }
      }
      spaceHomes.record(located, connected: Set(arrangement))
    }

    switch step {
    case .done:
      recordHomes()
      return .done
    case .keep(let i):
      recordHomes()
      Logger.spaces.debug(
        "display \(i + 1) has \(counts(i)) spaces, but no empty space can be destroyed")
      return .done
    case .move(let sid, let from, let to):
      Logger.spaces.debug(
        "move space \(Int64(bitPattern: sid.rawValue)) from display \(from + 1) to display \(to + 1)"
      )
      do { try moveSpace(sid, toDisplay: didList[to]) } catch { return .failed }
    case .create(let i, let pinnedDisplay):
      if let pinnedDisplay {
        Logger.spaces.debug(
          "display \(pinnedDisplay + 1) has only pinned spaces; create space on display \(i + 1) (\(counts(i)))"
        )
      } else {
        Logger.spaces.debug("create space on display \(i + 1) (\(counts(i)))")
      }
      do { try addSpace(onDisplayOf: didList[i].currentSpace) } catch { return .failed }
    case .destroy(let sid, let i):
      Logger.spaces.debug(
        "destroy empty space \(Int64(bitPattern: sid.rawValue)) on display \(i + 1) (\(counts(i)))")
      do { try destroySpace(sid) } catch { return .failed }
    }

    return .performed
  }

  /// Records the display a space moved to as its home, unless its home display is not connected (SpaceHomes).
  func recordSpaceHome(_ sid: SpaceID, on did: DisplayID) {
    guard let space = SLS.spaceName(SLS.connection, sid), let display = did.uuid,
      let connected = DisplayManager.shared.arrangedDisplays
    else { return }

    spaceHomes.record(space: space, display: display, connected: Set(connected))
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
