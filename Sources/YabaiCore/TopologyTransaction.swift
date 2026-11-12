//
// NOTE: The freeze of the desktop around a display change. A disturbance stops the commits of the ledger and everything
// that would act on a half-changed desktop. The displays of a dock return about 3 s apart, so the restore waits until the
// changes have been quiet for `quiet` seconds, and for no longer than `limit`. After the restore macOS can still
// move single windows, the latest about 10 s after the last display, so the desktop is watched for `watch` seconds
// before the commits start again. A new disturbance goes back to waiting from any phase.
//
// The restore puts back the shown spaces and the focused window only after a display came or went (`restoresFocus`):
// a sleep, a lock or a space that macOS replaced alone leaves the displays showing what they show, and the restore
// would switch the user back to the space of the commit, seconds after an unlock. A focus of the user during the
// transaction (`noteUserFocus`) also keeps the focus where it is.
//
// The clock is a parameter, so this is pure; SpaceManager+Topology.swift drives it.
//

/// Where the desktop is in a display change.
public struct TopologyTransaction: Equatable, Sendable {
  public enum Phase: Equatable, Sendable {
    /// Nothing is happening: the ledger follows the desktop.
    case stable
    /// macOS is changing the desktop.
    case disturbed
    /// The desktop is being put back.
    case restoring
    /// The desktop is back, and macOS may still move single windows.
    case watching
  }

  /// How long the changes must be quiet before the restore, in seconds.
  public static let quiet = 4.0

  /// The longest wait for the changes to end, in seconds.
  public static let limit = 30.0

  /// How long the desktop is watched after a restore that followed a change of the displays, in seconds.
  public static let watch = 15.0

  public private(set) var phase = Phase.stable
  /// The first disturbance of the transaction, the time the restore looks back from.
  public private(set) var firstChange = 0.0
  private var waitStart = 0.0
  private var lastChange = 0.0
  private var watchEnd = 0.0
  /// Whether a display came or went.
  public private(set) var displaysChanged = false
  /// Whether the user changed the focus since the first disturbance.
  public private(set) var userFocused = false

  public init() {}

  /// Whether the desktop must not be acted on: passes of the layout and pins wait, and commits stop.
  public var isFrozen: Bool { phase != .stable }

  /// Whether the views must leave the windows alone, because what is on a space is not final yet.
  public var holdsWindows: Bool { phase == .disturbed || phase == .restoring }

  /// Whether the restore shows the spaces of the commit and focuses its window.
  public var restoresFocus: Bool { displaysChanged && !userFocused }

  /// When the restore starts, while waiting for it.
  public var restoreTime: Double { min(lastChange + Self.quiet, waitStart + Self.limit) }

  /// Whether the watch is over.
  public func watchHasEnded(at now: Double) -> Bool { now >= watchEnd }

  /// A change that macOS made. `displays` tells that a display came or went.
  public mutating func disturb(at now: Double, displays: Bool) {
    if phase == .stable {
      firstChange = now
      displaysChanged = false
      userFocused = false
    }
    if phase != .disturbed { waitStart = now }

    phase = .disturbed
    lastChange = max(lastChange, now)
    displaysChanged = displaysChanged || displays
  }

  /// A change that does not start a transaction, but shows that one is still going on.
  public mutating func touch(at now: Double) {
    if phase == .disturbed { lastChange = max(lastChange, now) }
  }

  /// The user focused a space, display or window, clicked, or opened Mission Control; nothing while stable.
  public mutating func noteUserFocus() {
    if phase != .stable { userFocused = true }
  }

  public mutating func beginRestore() {
    phase = .restoring
  }

  /// The desktop is back. Only a change of the displays can bring late windows, so anything else ends here.
  public mutating func finishRestore(at now: Double) {
    guard displaysChanged else {
      finish()
      return
    }

    phase = .watching
    watchEnd = now + Self.watch
  }

  public mutating func finish() {
    phase = .stable
  }
}
