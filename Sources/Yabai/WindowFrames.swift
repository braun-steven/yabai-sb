import ApplicationServices
import CPrivate
import Logging
import YabaiCore

//
// NOTE: Moving and resizing windows: frame requests that are grouped per application and skipped when
// the window is already there.
//

/// A window and the frame it gets.
struct WindowPlacement {
  var window: Window!
  var x: Float, y: Float, w: Float, h: Float
}

//
// NOTE(asmvik): Attempting to check the window frame cache to prevent unnecessary movement and resize calls to the AX API
// is not reliable because it is possible to perform operations that should be applied, at a higher rate than the AX API events
// are received, causing our cache to become out of date and incorrectly guard against some changes that **should** be applied.
// This causes the window layout to **not** be modified the way we expect.
//
// A possible solution is to use the faster CG window notifications, as they are **a lot** more responsive, and can be used to
// track changes to the window frame in real-time without delay.
//
// NOTE: We therefore compare against the bounds of the window server instead, which change as soon as the window is moved,
// and against the frame we requested last. The window is only skipped when both match the target. If an application has not
// yet applied a previous request, the request differs from the target and the frame is set again.
//

extension CGRect {
  func isClose(x: Float, y: Float, w: Float, h: Float) -> Bool {
    return abs(Float(origin.x) - x) < 1 && abs(Float(origin.y) - y) < 1 && abs(Float(width) - w) < 1
      && abs(Float(height) - h) < 1
  }
}

extension WindowManager {
  static func frameNeedsUpdate(
    request: CGRect, bounds: CGRect?, x: Float, y: Float, w: Float, h: Float
  ) -> Bool {
    if !request.isClose(x: x, y: y, w: w, h: h) { return true }
    guard let bounds else { return true }
    return !bounds.isClose(x: x, y: y, w: w, h: h)
  }
}

extension Window {
  fileprivate func frameNeedsUpdate(x: Float, y: Float, w: Float, h: Float) -> Bool {
    if !frameRequest.isClose(x: x, y: y, w: w, h: h) { return true }
    return WindowManager.frameNeedsUpdate(
      request: frameRequest, bounds: SLS.windowBounds(SLS.connection, id), x: x, y: y, w: w, h: h)
  }
}

extension WindowManager {
  /// Moves the windows to their placements, skipping the windows that are already there.
  func placeWindows(_ list: [WindowPlacement]) {
    if Headless.isEnabled {
      Headless.apply(list)
      return
    }
    let list = list.filter { $0.window.frameNeedsUpdate(x: $0.x, y: $0.y, w: $0.w, h: $0.h) }
    if list.isEmpty { return }
    setWindowFrames(list)
  }

  func placeWindow(_ placement: WindowPlacement) {
    if Headless.isEnabled {
      Headless.apply([placement])
      return
    }
    if !placement.window.frameNeedsUpdate(
      x: placement.x, y: placement.y, w: placement.w, h: placement.h)
    {
      return
    }
    placement.window.setFrame(
      x: placement.x, y: placement.y, width: placement.w, height: placement.h)
  }
}

extension AXUIElement {
  @discardableResult
  fileprivate func setFrame(position: CGPoint, size: CGSize) -> AXError {
    //
    // NOTE: An application that does not respond makes every call wait for the messaging timeout,
    // so the remaining calls are skipped once one of them could not complete.
    //
    // NOTE(asmvik): Due to macOS constraints (visible screen-area), we might need to resize the window *before* moving it.
    var result = setAttribute(kAXSizeAttribute, to: size)
    if result != .cannotComplete { result = setAttribute(kAXPositionAttribute, to: position) }
    // NOTE(asmvik): Due to macOS constraints (visible screen-area), we might need to resize the window *after* moving it.
    if result != .cannotComplete { result = setAttribute(kAXSizeAttribute, to: size) }
    return result
  }
}

/// How a frame write treats AXEnhancedUserInterface: `write` turns it off for that write only; `drag` writes inside the
/// EUI scope of a resize drag (`MouseState.beginFrameScope`), which has turned it off already.
enum EUIScope {
  case write
  case drag
}

extension WindowManager {
  //
  // NOTE: The one AX frame write of a window: size, position, size (`AXUIElement.setFrame`), with EUI off around it for
  // `.write`. The frame request is recorded first, as the layout paths read it.
  //

  func applyFrame(_ window: Window, frame: CGRect, euiScope: EUIScope) {
    window.frameRequest = frame
    switch euiScope {
    case .write:
      window.application.ref.withEnhancedUserInterfaceDisabled {
        _ = window.ref?.setFrame(position: frame.origin, size: frame.size)
      }
    case .drag:
      _ = window.ref?.setFrame(position: frame.origin, size: frame.size)
    }
  }
}

extension Window {
  func setFrame(x: Float, y: Float, width: Float, height: Float) {
    WindowManager.shared.applyFrame(
      self,
      frame: CGRect(x: CGFloat(x), y: CGFloat(y), width: CGFloat(width), height: CGFloat(height)),
      euiScope: .write)
  }
}

//
// NOTE: The frames of a batch are set per application. AXEnhancedUserInterface is turned off once for
// each application instead of once for each window, and the applications are handled concurrently, so
// that an application that is slow to respond does not delay the windows of all other applications.
// The groups are built on the event loop thread; the worker threads only read the AX references of their
// own group and write its result, and must not touch global state.
//

struct WindowFrameRequest {
  let ref: AXUIElement
  let position: CGPoint
  let size: CGSize
}

// NOTE: @unchecked Sendable: the group holds non-Sendable AX references and a mutable error. One worker owns each
// group's error, and the event loop reads it after concurrentPerform joins. AX references are retained for the batch;
// workers never touch a model object.
final class WindowFrameGroup: @unchecked Sendable {
  let application: Application
  let ref: AXUIElement
  let name: String
  var list: [WindowFrameRequest] = []
  var error = AXError.success

  @WM init(_ target: Application) {
    application = target
    ref = target.ref
    name = target.name
  }

  @WM static func groups(for list: [WindowPlacement]) -> [WindowFrameGroup] {
    var result: [WindowFrameGroup] = []
    for placement in list {
      guard let owner = placement.window.application else {
        Logger.windows.debug("\(placement.window.id): has no application, not setting its frame")
        continue
      }
      guard let reference = placement.window.ref else {
        Logger.windows.debug("\(placement.window.id): has no AX element, not setting its frame")
        continue
      }
      let group: WindowFrameGroup
      if let existing = result.first(where: { $0.application == owner }) {
        group = existing
      } else {
        group = WindowFrameGroup(owner)
        result.append(group)
      }
      group.list.append(
        WindowFrameRequest(
          ref: reference,
          position: CGPoint(x: CGFloat(placement.x), y: CGFloat(placement.y)),
          size: CGSize(width: CGFloat(placement.w), height: CGFloat(placement.h))))
    }
    return result
  }

  func apply() {
    let attribute = AXUIElement.enhancedUserInterfaceAttribute
    let (value, result) = ref.attributeValue(attribute)
    if result == .cannotComplete {
      error = result
      return
    }
    let eui = value.map { CFBooleanGetValue(unsafeDowncast($0, to: CFBoolean.self)) } ?? false
    if eui { ref.setAttribute(attribute, to: false) }
    for request in list {
      let frameResult = request.ref.setFrame(position: request.position, size: request.size)
      if frameResult == .cannotComplete {
        error = frameResult
        break
      }
    }
    if eui { ref.setAttribute(attribute, to: true) }
  }
}

extension WindowManager {
  /// Sets the frames of the placements. Every write records the outcome of its application's calls, so a write that
  /// times out opens the application's breaker.
  func setWindowFrames(_ list: [WindowPlacement]) {
    if list.isEmpty { return }
    for placement in list {
      placement.window.frameRequest = CGRect(
        x: CGFloat(placement.x), y: CGFloat(placement.y),
        width: CGFloat(placement.w), height: CGFloat(placement.h))
    }
    let groups = WindowFrameGroup.groups(for: list)
    if groups.count == 1 {
      groups[0].apply()
    } else {
      DispatchQueue.concurrentPerform(iterations: groups.count) { groups[$0].apply() }
    }
    for group in groups {
      recordAXResult(group.error, pid: group.application.pid)
    }
    for group in groups where group.error == .cannotComplete {
      Logger.windows.notice(
        "\(group.name) did not respond, \(group.list.count) window(s) may not have been moved")
    }
  }
}
