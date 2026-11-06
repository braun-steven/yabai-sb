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

/// What a space layout pass reads about the displays and their spaces, in arrangement order.
struct SpaceLayoutInputs {
  var displays: [DisplayID]
  var arrangement: [String]
  var target: [Int]
  var spaces: [[SpaceID]]
  var user: [[Bool]]
  var uuids: [SpaceID: String]
}

extension SpaceManager {
  /// Reads the displays and spaces for a pass; `.success(nil)` when no layout applies to the displays.
  func spaceLayoutInputs() -> Result<SpaceLayoutInputs?, SpaceOperationError> {
    //
    // NOTE: Each pass reads the lists again: the previous pass may have changed them, and the next one decides on them.
    //
    DisplayManager.shared.invalidateSpaceCaches()

    let displayCount = DisplayID.count
    if displayCount < 1 || displayCount > SpaceLayout.max { return .success(nil) }

    guard
      let layout = SpaceLayout.select(
        from: Config.current.space.spaceLayouts, displayCount: displayCount,
        hasBuiltin: DisplayID.all.contains { CGDisplayIsBuiltin($0.rawValue) != 0 })
    else {
      Logger.spaces.debug("no space_layout for \(displayCount) display(s)")
      return .success(nil)
    }

    var didList: [DisplayID] = []
    var arrangement: [String] = []
    var builtin: Int?

    for i in 0..<displayCount {
      guard let uuid = DisplayManager.shared.arrangedDisplayUUID(i + 1),
        let did = DisplayID(uuid: uuid)
      else { return .failure(.missingSource) }

      didList.append(did)
      arrangement.append(uuid)
      if builtin == nil && CGDisplayIsBuiltin(did.rawValue) != 0 { builtin = i }
    }

    var spaces: [[SpaceID]] = []
    for did in didList {
      guard let list = did.spaces else { return .failure(.missingSource) }
      spaces.append(list)
    }
    let user = spaces.map { $0.map(\.isUser) }

    var uuids: [SpaceID: String] = [:]
    for (i, list) in spaces.enumerated() {
      for (j, sid) in list.enumerated() where user[i][j] {
        uuids[sid] = SLS.spaceName(SLS.connection, sid)
      }
    }

    return .success(
      SpaceLayoutInputs(
        displays: didList, arrangement: arrangement, target: layout.targets(builtin: builtin),
        spaces: spaces, user: user, uuids: uuids))
  }

  /// Performs one step that moves the user spaces towards the layout of the displays.
  func reconcileSpaceLayout() -> ReconcileResult {
    let inputs: SpaceLayoutInputs
    switch spaceLayoutInputs() {
    case .success(let read?): inputs = read
    case .success(nil): return .done
    case .failure: return .failed
    }

    //
    // NOTE: The spaces whose display went away go back to it when it is connected again (SpaceHomes): the layout
    // takes them first for that display. The homes are recorded once the counts match, and by every space move.
    //
    let home = spaceHomes.homeIndices(
      of: Array(inputs.uuids.keys), spaceUUID: { inputs.uuids[$0] },
      arrangement: inputs.arrangement)

    //
    // NOTE: The pinned spaces (see SpacePinning.pinnedSpaces) are never moved or destroyed here. The pin reconcile moves
    // them to their displays, so a layout move of one would be undone by its pin, and the two would ping-pong.
    //
    let step = SpaceLayout.reconcileStep(
      target: inputs.target, spaces: inputs.spaces, user: inputs.user, pinned: pinnedSpaces(),
      home: home, visible: { inputs.displays[$0].currentSpace },
      isEmpty: { $0.windows(includingMinimized: true)?.isEmpty ?? false })

    return perform(step, inputs)
  }

  /// Performs a step of the spaces.
  func perform(_ step: SpaceLayoutStep, _ inputs: SpaceLayoutInputs) -> ReconcileResult {
    let didList = inputs.displays
    let target = inputs.target
    let user = inputs.user

    TopologyLog.record(
      "layout-step", "\(step) target=\(target) counts=\(user.map { $0.count(where: { $0 }) })")

    /// The user spaces and the target of a display, for the log.
    func counts(_ i: Int) -> String { "\(user[i].count(where: { $0 }))/\(target[i])" }

    /// Records the display of every user space as its home, once the pass has nothing left to do.
    func recordHomes() {
      var located: [String: String] = [:]
      for (i, list) in inputs.spaces.enumerated() {
        for sid in list {
          if let uuid = inputs.uuids[sid] { located[uuid] = inputs.arrangement[i] }
        }
      }
      spaceHomes.record(located, connected: Set(inputs.arrangement))
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
    case .reorder(let sid, let other, let i):
      Logger.spaces.debug(
        "move space \(Int64(bitPattern: sid.rawValue)) to the place of \(Int64(bitPattern: other.rawValue)) on display \(i + 1)"
      )
      do { try moveSpace(sid, to: other) } catch { return .failed }
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
