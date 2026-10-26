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
  /// (`resolvePendingSpaceFocus`).
  var pendingSpaceFocus: PendingSpaceFocus?

  /// A space focus request, made at `time` on the OSTimer clock.
  struct PendingSpaceFocus: Equatable {
    var sid: SpaceID
    var time: UInt64
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
