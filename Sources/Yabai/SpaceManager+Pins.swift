import Logging
import YabaiCore

//
// NOTE: The pins of labelled spaces (SpacePins and SpacePinning in YabaiCore): the lookups that the pins need from the
// window server, the reconcile pass that moves one pinned space to its display, and the query of a space's pin. The
// pure decisions are in YabaiCore; the events are in EventHandler+System.swift (spacePinReconcile).
//

extension SpaceManager {
  /// The connected displays by uuid.
  func connectedDisplays() -> [String: DisplayID] {
    var result: [String: DisplayID] = [:]

    for uuid in DisplayManager.shared.arrangedDisplays ?? [] {
      if let did = DisplayID(uuid: uuid) { result[uuid] = did }
    }

    return result
  }

  /// The space that each pinned label names. A label that names no space is left out.
  private func pinnedSpaceIDs() -> [String: SpaceID] {
    var result: [String: SpaceID] = [:]

    for label in pins.labels {
      if let sid = labels.id(named: label) { result[label] = sid }
    }

    return result
  }

  /// The spaces that the space layout must keep (SpacePinning.pinnedSpaces).
  func pinnedSpaces() -> Set<SpaceID> {
    if pins.isEmpty { return [] }

    return SpacePinning.pinnedSpaces(
      pins: pins, spaceOf: pinnedSpaceIDs(), connected: connectedDisplays())
  }

  /// The moves that bring the pinned spaces to their displays, in label order (SpacePinning.moves).
  func spacePinMoves() -> [SpacePinMove] {
    if pins.isEmpty { return [] }

    let spaceOf = pinnedSpaceIDs()
    var displayOf: [SpaceID: DisplayID] = [:]
    for sid in spaceOf.values {
      if let did = sid.display { displayOf[sid] = did }
    }

    return SpacePinning.moves(
      pins: pins, spaceOf: spaceOf, displayOf: displayOf, connected: connectedDisplays())
  }

  /// The arrangement index of the display that the space is pinned to. 0 when the space has no pin or its display is
  /// not connected.
  func pinnedArrangement(of sid: SpaceID) -> Int {
    guard let label = labels.name(of: sid), let uuid = pins.display(of: label),
      let index = DisplayID(uuid: uuid)?.arrangement
    else { return 0 }

    return index
  }

  /// Removes the pins of the labels that no space has any more: a label that is removed or replaced takes its pin.
  func dropOrphanedPins() {
    for label in pins.labels where labels.id(named: label) == nil {
      pins.unpin(label: label)
    }
  }

  //
  // NOTE: Keyed like the space layout reconcile: a new schedule supersedes the pending pass. resetPasses restarts the
  // limit of passes for a new change (a display or a pin); the passes of a running reconcile do not reset it.
  //

  /// Posts the pin reconcile event after the delay, superseding the pending one. Nothing is posted without pins.
  func schedulePinReconcile(after delay: Duration, resetPasses: Bool) {
    if pins.isEmpty { return }
    if resetPasses { spacePinPasses = 0 }

    EventLoop.post(.spacePinReconcile, after: delay, key: .spacePinReconcile)
  }

  /// Performs one step that moves a pinned space to its display. Without the scripting addition the move fails: the
  /// notice is logged once per daemon run, and the pins wait for the next change.
  func reconcileSpacePins() -> ReconcileResult {
    //
    // NOTE: Each pass reads the lists again: the previous pass may have changed them.
    //
    DisplayManager.shared.invalidateSpaceCaches()

    guard let move = spacePinMoves().first else { return .done }

    Logger.spaces.debug(
      "move pinned space \(Int64(bitPattern: move.sid.rawValue)) to display \(move.did)")

    do {
      try moveSpace(move.sid, toDisplay: move.did)
    } catch .scriptingAdditionFailed {
      if !spacePinNoticeLogged {
        spacePinNoticeLogged = true
        Logger.spaces.notice(
          "space pins need the scripting addition: pinned spaces are not moved to their displays")
      }
      return .done
    } catch {
      return .failed
    }

    return .performed
  }
}
