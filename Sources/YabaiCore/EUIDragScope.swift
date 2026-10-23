//
// NOTE: AXEnhancedUserInterface (EUI) is turned off around a frame write, because some applications animate the change
// otherwise. A resize drag writes many frames, so EUI is turned off once, by the drag's first frame, and restored when
// the drag ends, instead of once per frame. This state decides those steps without the Accessibility API, so the
// tests can replay a drag. The caller reads EUI when the scope begins, runs the returned steps, and runs `end` on every
// exit path of the drag: the drag end, a cancelled drag, a window destroyed during it and a terminated application.
//

/// One change of the EUI attribute of the application that owns a drag.
public enum EUIStep: Equatable {
  case disable
  case restore
}

/// The EUI scope of one resize drag: opened by its first frame, closed by `end`. A scope that is already open (or
/// that began while EUI was off) changes nothing, and closing it restores EUI only if `begin` turned it off.
public struct EUIDragScope: Equatable {
  /// nil while no drag is open; otherwise whether `end` must restore EUI, which is whether it was on when `begin` ran.
  public private(set) var restoreOnEnd: Bool?

  public init() {}

  public var isOpen: Bool { restoreOnEnd != nil }

  /// Opens the scope, given the value of EUI at the drag's first frame. Returns the step that turns EUI off.
  @discardableResult
  public mutating func begin(enabled: Bool) -> [EUIStep] {
    guard restoreOnEnd == nil else { return [] }
    restoreOnEnd = enabled
    return enabled ? [.disable] : []
  }

  /// Closes the scope. Returns the step that turns EUI back on, when `begin` turned it off; nothing when no scope is open.
  @discardableResult
  public mutating func end() -> [EUIStep] {
    guard let restore = restoreOnEnd else { return [] }
    restoreOnEnd = nil
    return restore ? [.restore] : []
  }
}
