import ApplicationServices
import CPrivate
import CoreGraphics
import Foundation
import Logging
import OrderedCollections
import SortedCollections
import YabaiCore

//
// NOTE: The spaces of yabai: the views of every space (a table from the space id to its view), their invalidation and
// refresh. The layout and padding commands of spaces are in SpaceManager+Layout.swift, the space operations in
// SpaceManager+Operations.swift and the space layout in SpaceManager+SpaceLayout.swift.
//

/// Why a space operation failed (`checkSpaceOperation` in MessageSpace.swift words the failures every space command shares).
enum SpaceOperationError: Error, Sendable {
  case missingSource
  case missingDestination
  case invalidSource
  case invalidDestination
  case invalidType
  case sameSpace
  case sameDisplay
  case inMissionControl
  case scriptingAdditionFailed
}

@WM final class SpaceManager {
  /// See the NOTE of `DisplayManager.shared`.
  static let shared = SpaceManager()

  var views: SortedDictionary<SpaceID, View> = [:]
  var currentSpaceID: SpaceID?
  var lastSpaceID: SpaceID?
  var didBegin = false
  var labels = LabelList<SpaceID>()
  var spaceLayoutPasses = 0
  /// The pins of the labels (SpacePins), kept in memory: the config file sets them again at startup.
  var pins = SpacePins()
  var spacePinPasses = 0
  /// Whether the notice about the pins without the scripting addition was logged (once per daemon run).
  var spacePinNoticeLogged = false
  /// A space that `space --focus` switched to on the same display, whose window gets focus once the switch is reported
  /// (`resolvePendingSpaceFocus`), or a space that `space --display` moved, focused once the move is reported
  /// (`resolvePendingSpaceMove`).
  var pendingSpaceFocus: PendingSpaceFocus?
  /// The spaces `moveSpace(_:toDisplay:)` moved that the window server has not reported on their new display yet
  /// (`resolveSpaceMoveRefresh`).
  var pendingSpaceMoves: [PendingSpaceMove] = []

  /// A space focus request, made at `time` on the OSTimer clock.
  struct PendingSpaceFocus: Equatable {
    var sid: SpaceID
    var time: UInt64
    /// The display `space --display` moved the space to; nil for a switch on the same display.
    var display: DisplayID?
  }

  /// The view of a space; before `begin()` only a known one, after it the view is created when the space is new.
  func queryView(for sid: SpaceID) -> View? {
    if didBegin { return view(for: sid) }

    return views[sid]
  }

  /// The view of a space; it is created when the space is new.
  @discardableResult
  func view(for sid: SpaceID) -> View {
    if let found = views[sid] { return found }

    let created = View.create(sid: sid)
    views[sid] = created
    return created
  }

  func refreshView(for sid: SpaceID) {
    let target = view(for: sid)
    if target.layout == .float { return }

    target.updateAndFlush()
  }

  func markViewInvalid(for sid: SpaceID) {
    let target = view(for: sid)
    if target.layout == .float { return }

    target.isValid = false
  }

  func markSpacesInvalid(on did: DisplayID) {
    guard let spaceList = did.spaces else { return }

    let sid = did.currentSpace
    for space in spaceList {
      if space == sid, let sid {
        refreshView(for: sid)
      } else {
        markViewInvalid(for: space)
      }
    }
  }

  func markSpacesInvalid() {
    // NOTE: In headless mode only the seeded views are marked, not the spaces of the user's displays; the view of
    // Headless.activeSpace is refreshed like the current space of a display.
    if Headless.isEnabled {
      for sid in views.keys {
        if sid == Headless.activeSpace { refreshView(for: sid) } else { markViewInvalid(for: sid) }
      }
      return
    }

    for did in DisplayID.all {
      markSpacesInvalid(on: did)
    }
  }

  //
  // NOTE: A space that moves to another display keeps the tree of its old display until it is updated: `moveSpace` only
  // marks its view invalid, the window server sends no space or display event for a move of a hidden space, and
  // `refreshCurrentSpace` updates only the active space. A refresh pass brings every shown space up to date for its
  // display (and, with `includingHidden`, lays out the hidden stale ones without moving their windows: `View.flush`
  // keeps a hidden view dirty until it is shown). It runs after a space change (a display can show another space without
  // the focus moving: `display --space`), once the window server has a space moved by `moveSpace` on its new display
  // (`resolveSpaceMoveRefresh`), and after a display is added, removed, moved or resized (`displaySpacesRefresh`). The
  // view that holds the window of a mouse drag is left alone: its windows move between displays during the drag.
  //

  /// A space of a refresh pass: the frame of its display now (nil without one) and whether the display shows it.
  struct SpaceRefreshEntry: Equatable {
    var sid: SpaceID
    var frame: CGRect?
    var isVisible: Bool
  }

  /// Brings the known views of `entries` up to date (`View.refreshStep(frame:isVisible:)`), except the view that holds
  /// `dragged`.
  func refreshSpaces(_ entries: [SpaceRefreshEntry], dragged: WindowID?) {
    for entry in entries {
      guard let target = views[entry.sid] else { continue }
      if let dragged, target.findWindow(dragged) != nil { continue }

      switch target.refreshStep(frame: entry.frame, isVisible: entry.isVisible) {
      case .update: target.updateAndFlush()
      case .flush: target.flush()
      case .none: break
      }
    }
  }

  /// The user spaces of every display for a refresh pass: the shown ones, and with `includingHidden` all of them. In
  /// headless mode the seeded views, shown when they are `Headless.activeSpace`.
  func spaceRefreshEntries(includingHidden: Bool) -> [SpaceRefreshEntry] {
    if Headless.isEnabled {
      return views.keys.compactMap { sid in
        let isVisible = sid == Headless.activeSpace
        guard isVisible || includingHidden else { return nil }
        return SpaceRefreshEntry(sid: sid, frame: Headless.displayFrame, isVisible: isVisible)
      }
    }

    var entries: [SpaceRefreshEntry] = []
    for did in DisplayID.all {
      let frame = did.constrainedBounds(ignoringExternalBar: false)
      let current = did.currentSpace
      let spaceList = includingHidden ? did.spaces ?? [] : current.map { [$0] } ?? []
      for sid in spaceList where sid.isUser {
        entries.append(SpaceRefreshEntry(sid: sid, frame: frame, isVisible: sid == current))
      }
    }
    return entries
  }

  /// Runs a refresh pass of the spaces of every display, unless Mission Control is active.
  func refreshDisplaySpaces(includingHidden: Bool) {
    if MissionControl.shared.isActive { return }

    let ms = MouseState.shared
    let dragged = ms.currentAction == .none ? nil : ms.window?.id
    refreshSpaces(spaceRefreshEntries(includingHidden: includingHidden), dragged: dragged)
  }

  /// How long after a display is added, removed, moved or resized the refresh pass runs: the window server moves the
  /// spaces of a removed or returning display after the display event.
  static let displaySpacesRefreshDelay: Duration = .milliseconds(500)

  /// Schedules the refresh pass after a display change; a newer change replaces the pending one.
  func scheduleDisplaySpacesRefresh() {
    EventLoop.post(
      .displaySpacesRefresh, after: Self.displaySpacesRefreshDelay, key: .displaySpacesRefresh)
  }

  /// A space moved by `moveSpace(_:toDisplay:)` at `time` (OSTimer clock), whose views are refreshed once the window
  /// server has it on `display`.
  struct PendingSpaceMove: Equatable {
    var sid: SpaceID
    var display: DisplayID
    var time: UInt64
  }

  /// Records a moved space; a newer move of the same space replaces the older one.
  func recordSpaceMove(_ sid: SpaceID, to display: DisplayID, at time: UInt64) {
    pendingSpaceMoves.removeAll { $0.sid == sid }
    pendingSpaceMoves.append(PendingSpaceMove(sid: sid, display: display, time: time))
  }

  /// Drops the moves whose space the window server has on its new display (`display`), and the moves older than
  /// `pendingSpaceFocusTimeoutMs` at `now`. Returns whether it dropped one: the spaces need a refresh pass then.
  func consumeSpaceMoves(display: (SpaceID) -> DisplayID?, now: UInt64) -> Bool {
    let count = pendingSpaceMoves.count
    pendingSpaceMoves.removeAll { move in
      display(move.sid) == move.display
        || OSTimer.milliseconds(from: move.time, to: now) >= Self.pendingSpaceFocusTimeoutMs
    }
    return pendingSpaceMoves.count != count
  }

  /// Refreshes the spaces once the window server has a moved space on its new display; until then it checks again on
  /// the event loop.
  func resolveSpaceMoveRefresh() {
    DisplayManager.shared.invalidateSpaceCaches()

    let arrived = consumeSpaceMoves(display: { $0.display }, now: OSTimer.now)
    if !pendingSpaceMoves.isEmpty {
      EventLoop.post(
        .spaceMoveRefreshCheck, after: Self.pendingSpaceMoveInterval, key: .spaceMoveRefresh)
    }
    if arrived { refreshDisplaySpaces(includingHidden: true) }
  }

  func refreshApplicationWindows() -> Bool {
    let wm = WindowManager.shared

    if wm.applicationsToRefresh.isEmpty { return false }

    let windowCount = wm.window.count
    // NOTE: Iterates a copy: a resolved application leaves the list.
    for application in wm.applicationsToRefresh {
      Logger.spaces.debug("\(application.name) has windows that are not yet resolved")
      wm.addExistingApplicationWindows(application, isRefreshing: true)
    }

    return windowCount != wm.window.count
  }

  /// The views of the spaces of a new display keep their names, and take the new ids.
  func handleDisplayAdd(_ did: DisplayID) {
    guard let spaceList = did.spaces else { return }

    var viewList: [View?] = views.values.map { Optional($0) }
    var uuidList: [CFString?] = viewList.map { $0?.uuid }

    for sid in spaceList {
      guard let uuid = SLS.spaceNameObject(SLS.connection, sid) else { continue }

      for j in 0..<viewList.count {
        guard let viewUUID = uuidList[j], let target = viewList[j] else { continue }
        if !CFEqual(viewUUID, uuid) { continue }

        uuidList[j] = nil
        viewList[j] = nil

        views[target.sid] = nil

        labels.replace(id: target.sid, with: sid)

        target.sid = sid
        target.uuid = uuid

        if views[sid] == nil { views[sid] = target }
        break
      }
    }

    currentSpaceID = SpaceID.active
    lastSpaceID = currentSpaceID
  }

  /// An empty table of labels and views. The space defaults in Config are not written here: the startup sequence
  /// sets them (`Config.applySpaceDefaults()`) before this manager begins.
  func resetViews() {
    labels = LabelList<SpaceID>()
    pins = SpacePins()
    pendingSpaceFocus = nil
    pendingSpaceMoves = []
    //
    // NOTE: The views are keyed by space id.
    //

    views = [:]
  }

  /// Creates the views of every space of every display. Reads the space defaults of Config, so those are set first.
  func begin() {
    resetViews()

    for did in DisplayID.all {
      guard let spaceList = did.spaces else { continue }

      for sid in spaceList {
        let created = View.create(sid: sid)
        if views[sid] == nil { views[sid] = created }
      }
    }

    currentSpaceID = SpaceID.active
    lastSpaceID = currentSpaceID
    didBegin = true
  }
}

extension ViewSpacing {
  /// The field of SpaceDefaults that views without their own value use.
  @WM var spaceDefault: WritableKeyPath<SpaceDefaults, Int> {
    switch self {
    case .topPadding: \.topPadding
    case .bottomPadding: \.bottomPadding
    case .leftPadding: \.leftPadding
    case .rightPadding: \.rightPadding
    case .windowGap: \.windowGap
    }
  }
}
