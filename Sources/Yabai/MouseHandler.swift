import ApplicationServices
import CPrivate
import Synchronization
import YabaiCore

// The event tap runs on the main run loop and only posts events.

/// What a mouse drag does (`config mouse_action1`, `mouse_action2`, `mouse_drop_action`), named by its config value.
enum MouseAction: String, Sendable {
  case none
  case move
  case resize
  case swap
  case stack
}

/// Where a dragged window is dropped on a managed window: nowhere, its center (stack or swap) or one of its edges.
enum MouseDropAction: Sendable {
  case none
  case stack
  case swap
  case warpTop
  case warpRight
  case warpBottom
  case warpLeft
}

/// The modifier keys held during a mouse event, as far as mouse actions tell them apart.
struct MouseModifiers: OptionSet, Sendable {
  let rawValue: UInt8

  static let alt = MouseModifiers(rawValue: 0x02)
  static let shift = MouseModifiers(rawValue: 0x04)
  static let cmd = MouseModifiers(rawValue: 0x08)
  static let ctrl = MouseModifiers(rawValue: 0x10)
  static let fn = MouseModifiers(rawValue: 0x20)
}

/// The key that has to be held, alone, for the mouse actions (`config mouse_modifier`).
enum MouseModifierKey: String, CaseIterable, Sendable {
  case alt
  case shift
  case cmd
  case ctrl
  case fn

  var modifiers: MouseModifiers {
    switch self {
    case .alt: .alt
    case .shift: .shift
    case .cmd: .cmd
    case .ctrl: .ctrl
    case .fn: .fn
    }
  }
}

//
// NOTE: The private event type, fields and values of the Dock swipe gesture that switches spaces (SkyLight's values;
// CGEventField and CGEventType have no cases for them).
//

enum DockSwipe {
  static let eventType: UInt32 = 30  // kCGSEventDockControl
  static let typeField = CGEventField(rawValue: 55)!  // kCGSEventTypeField
  static let hidTypeField = CGEventField(rawValue: 110)!  // kCGEventGestureHIDType
  static let motionField = CGEventField(rawValue: 123)!  // kCGEventGestureSwipeMotion
  static let progressField = CGEventField(rawValue: 124)!  // kCGEventGestureSwipeProgress
  static let velocityXField = CGEventField(rawValue: 129)!  // kCGEventGestureSwipeVelocityX
  static let phaseField = CGEventField(rawValue: 132)!  // kCGEventGesturePhase
  static let hidType: Int64 = 23  // kIOHIDEventTypeDockSwipe
  static let motionHorizontal: Int64 = 1  // kCGGestureMotionHorizontal
  static let phaseBegan: Int64 = 1  // kCGSGesturePhaseBegan
  static let phaseEnded: Int64 = 4  // kCGSGesturePhaseEnded
  static let phaseCancelled: Int64 = 8  // kCGSGesturePhaseCancelled
}

//
// NOTE: The click that focuses a display or a space (`postFocusClick`) replaces CGPostMouseEvent, which is deprecated
// and unavailable to Swift. A CGEvent posted at .cghidEventTap passes through this tap too, so the events carry
// `SyntheticClick.userData` as their source user data, and the callback returns them untouched: the window server
// still gets the click, but yabai skips its own mouse handling (drag and drop, tab bar clicks, mouse modifier actions).
// The click is a left click at point, click count one, and the cursor is not moved: both callers warp it to point
// before the click, as they did with updateMouseCursorPosition false. The SDK headers do not say whether
// CGPostMouseEvent also passed through this tap, so this is the one behavior the replacement could not confirm.
//

enum SyntheticClick {
  /// The source user data of the clicks yabai posts: "yabai" in ASCII.
  static let userData: Int64 = 0x7961_6261_69
}

/// Clicks the left button at point, to focus a display or a space. The caller has moved the cursor to point.
func postFocusClick(at point: CGPoint) {
  for type in [CGEventType.leftMouseDown, CGEventType.leftMouseUp] {
    guard
      let event = CGEvent(
        mouseEventSource: nil, mouseType: type, mouseCursorPosition: point, mouseButton: .left)
    else { return }
    event.setIntegerValueField(.mouseEventClickState, value: 1)
    event.setIntegerValueField(.eventSourceUserData, value: SyntheticClick.userData)
    event.post(tap: .cghidEventTap)
  }
}

/// How a dragged window changed since the mouse went down.
struct MouseWindowChange: Sendable {
  var dx: Float = 0, dy: Float = 0, dw: Float = 0, dh: Float = 0
  var changedX = false, changedY = false
  var changedWidth = false, changedHeight = false
  var changedPosition = false
  var changedSize = false
}

/// State owned by the main run-loop event tap, with synchronized settings shared with yabai.wm.
final class MouseTapState {
  // NOTE: Only the event tap on the main run loop touches the click, drag and replay fields. The modifier, the port
  // (a +1 CFMachPort stored as its bit pattern) and `tracksFocus` are shared with yabai.wm, which sets the modifier
  // and creates and tears down the tap (`MouseState.beginEventTap`/`endEventTap`).
  private let modifierLock = Mutex(MouseModifierKey.fn)
  private let portLock = Mutex<UInt>(0)
  // NOTE: The tap receives moves for glass hover even when focus-follows-mouse is disabled.
  let tracksFocus = Atomic(false)
  var consumeMouseClick = false
  var consumeTabClick = false
  var dragDetected = false
  var consumedEvent: CGEvent?

  var modifier: MouseModifierKey
  {
    get { modifierLock.withLock { $0 } }
    set { modifierLock.withLock { $0 = newValue } }
  }

  func withPort<R>(_ body: (CFMachPort?) -> R) -> R {
    let retainedPort = portLock.withLock { rawPort -> Unmanaged<CFMachPort>? in
      guard rawPort != 0 else { return nil }
      let pointer = UnsafeMutableRawPointer(bitPattern: rawPort)!
      return Unmanaged<CFMachPort>.fromOpaque(pointer).retain()
    }
    guard let retainedPort else { return body(nil) }
    defer { retainedPort.release() }
    return body(retainedPort.takeUnretainedValue())
  }

  func retainPort(_ port: CFMachPort) {
    portLock.withLock { rawPort in
      rawPort = UInt(bitPattern: Unmanaged.passRetained(port).toOpaque())
    }
  }

  var hasPort: Bool {
    portLock.withLock { $0 != 0 }
  }

  func endEventTap(removeSource: () -> Void) {
    let retainedPointer = portLock.withLock { rawPort -> UnsafeMutableRawPointer? in
      guard rawPort != 0 else { return nil }
      let pointer = UnsafeMutableRawPointer(bitPattern: rawPort)!
      rawPort = 0
      return pointer
    }
    guard let retainedPointer else { return }
    let port = Unmanaged<CFMachPort>.fromOpaque(retainedPointer).takeUnretainedValue()
    CGEvent.tapEnable(tap: port, enable: false)
    CFMachPortInvalidate(port)
    removeSource()
    Unmanaged<CFMachPort>.fromOpaque(retainedPointer).release()
  }
}

/// The transient mouse action state used by yabai.wm while a window is being dragged.
@WM final class MouseState {
  static let shared = MouseState()

  // NOTE: The tap state is retained by this daemon-lifetime singleton and is passed unretained as callback context.
  let tap = MouseTapState()
  var runLoopSource: CFRunLoopSource?

  var currentAction = MouseAction.none
  var downLocation = CGPoint.zero
  var lastMovedTime: UInt64 = 0
  var window: Window!
  var windowFrame = CGRect.zero
  var ffmWindowID: WindowID?
  var direction: ResizeHandle = []
  var feedbackWindowID: WindowID?
  var feedbackDirection: InsertDirection?

  //
  // NOTE: The EUI scope of the resize drag in progress: EUI is off on frameApplication from the drag's first frame until
  // endFrameScope. Every path that ends the drag or drops its window ends the scope (mouse up, a mouse down that
  // arrives during a drag, invalid or destroyed windows, a terminated application), so EUI is never left off.
  //

  private var frameScope = EUIDragScope()
  private var frameApplication: Application?

  /// Clears the window of the drag, and closes the EUI scope of the drag.
  func clearWindow() {
    endFrameScope()
    window = nil
  }

  /// Opens the EUI scope of a resize drag on its first frame. A window of another application closes the open scope first.
  func beginFrameScope(of target: Window) {
    let application: Application = target.application
    if frameApplication != nil, frameApplication !== application { endFrameScope() }
    guard frameApplication == nil, let ref = application.ref else { return }

    let enabled = ref.boolAttribute(AXUIElement.enhancedUserInterfaceAttribute)
    frameApplication = application
    for step in frameScope.begin(enabled: enabled) {
      ref.setAttribute(AXUIElement.enhancedUserInterfaceAttribute, to: step == .restore)
    }
  }

  /// Closes the EUI scope of the drag, restoring EUI if the drag turned it off. Does nothing without an open scope.
  func endFrameScope() {
    guard let application = frameApplication else { return }
    frameApplication = nil
    let steps = frameScope.end()
    guard let ref = application.ref else { return }
    for step in steps {
      ref.setAttribute(AXUIElement.enhancedUserInterfaceAttribute, to: step == .restore)
    }
  }
}

extension MouseModifiers {
  init(_ flags: CGEventFlags) {
    self.init(rawValue: 0)
    if flags.contains(.maskAlternate) { insert(.alt) }
    if flags.contains(.maskShift) { insert(.shift) }
    if flags.contains(.maskCommand) { insert(.cmd) }
    if flags.contains(.maskControl) { insert(.ctrl) }
    if flags.contains(.maskSecondaryFn) { insert(.fn) }
  }
}

//
// NOTE: Focus follows mouse is paused while a horizontal swipe switches spaces, and for a moment after it.
//

private func mouseHandleDockGesture(_ event: CGEvent) {
  guard event.getIntegerValueField(DockSwipe.hidTypeField) == DockSwipe.hidType,
    event.getIntegerValueField(DockSwipe.motionField) == DockSwipe.motionHorizontal
  else { return }
  let phase = event.getIntegerValueField(DockSwipe.phaseField)
  if phase == DockSwipe.phaseBegan {
    pendingGesture.store(true, ordering: .releasing)
  } else if phase == DockSwipe.phaseEnded || phase == DockSwipe.phaseCancelled {
    pendingGesture.store(false, ordering: .releasing)
    lastGestureTime.store(OSTimer.now, ordering: .releasing)
  }
}

private func mouseHandler(
  _ proxy: CGEventTapProxy, _ type: CGEventType, _ event: CGEvent,
  _ context: UnsafeMutableRawPointer?
) -> Unmanaged<CGEvent>? {
  let tap = Unmanaged<MouseTapState>.fromOpaque(context!).takeUnretainedValue()
  // NOTE: Clicks posted by yabai (`postFocusClick`) pass through untouched, see `SyntheticClick`.
  if (type == .leftMouseDown || type == .leftMouseUp)
    && event.getIntegerValueField(.eventSourceUserData) == SyntheticClick.userData
  {
    return .passUnretained(event)
  }
  switch type {
  case .tapDisabledByTimeout, .tapDisabledByUserInput:
    tap.withPort { port in
      if let port { CGEvent.tapEnable(tap: port, enable: true) }
    }
  case .leftMouseDown, .rightMouseDown:
    let mod = MouseModifiers(event.flags)
    var tabWid: WindowID?
    if type == .leftMouseDown && mod != tap.modifier.modifiers
      && TabBar.hitTest(event.location, window: &tabWid)
    {
      TabBar.updatePointer(event.location, pressed: true)
      tap.consumeTabClick = true
      if let tabWid { EventLoop.post(.tabBarClicked(windowID: tabWid)) }
      return nil
    }
    EventLoop.post(.mouseDown(Handoff(value: .passRetained(event)), modifiers: mod))
    if mod == tap.modifier.modifiers {
      tap.consumeMouseClick = true
      tap.consumedEvent = event
      return nil
    }
  case .leftMouseUp, .rightMouseUp:
    if type == .leftMouseUp && tap.consumeTabClick {
      TabBar.updatePointer(event.location, pressed: false)
      tap.consumeTabClick = false
      return nil
    }
    EventLoop.post(.mouseUp(Handoff(value: .passRetained(event))))
    if tap.consumeMouseClick {
      if !tap.dragDetected {
        tap.consumedEvent!.tapPostEvent(proxy)
        event.tapPostEvent(proxy)
      }
      tap.dragDetected = false
      tap.consumeMouseClick = false
      tap.consumedEvent = nil
      return nil
    }
  case .leftMouseDragged, .rightMouseDragged:
    if type == .leftMouseDragged && tap.consumeTabClick {
      TabBar.updatePointer(event.location, pressed: true)
      return nil
    }
    tap.dragDetected = true
    _ = pendingMouseDragged.wrappingAdd(1, ordering: .acquiringAndReleasing)
    EventLoop.post(.mouseDragged(Handoff(value: .passRetained(event))))
  case .mouseMoved:
    TabBar.updatePointer(event.location, pressed: false)
    if !tap.tracksFocus.load(ordering: .relaxed) { return .passUnretained(event) }
    let mod = MouseModifiers(event.flags)
    if mod == tap.modifier.modifiers { return .passUnretained(event) }
    _ = pendingMouseMoved.wrappingAdd(1, ordering: .acquiringAndReleasing)
    EventLoop.post(.mouseMoved(Handoff(value: .passRetained(event)), modifiers: mod))
  default:
    if type.rawValue == DockSwipe.eventType { mouseHandleDockGesture(event) }
  }
  return .passUnretained(event)
}

extension MouseState {
  /// How the dragged window has changed since the mouse went down.
  @WM var windowChange: MouseWindowChange {
    let frame = window.frame
    var change = MouseWindowChange()
    change.dx = Float(frame.origin.x - windowFrame.origin.x)
    change.dy = Float(frame.origin.y - windowFrame.origin.y)
    change.dw = Float(frame.width - windowFrame.width)
    change.dh = Float(frame.height - windowFrame.height)
    change.changedX = change.dx != 0
    change.changedY = change.dy != 0
    change.changedWidth = change.dw != 0
    change.changedHeight = change.dh != 0
    change.changedPosition = change.changedX || change.changedY
    change.changedSize = change.changedWidth || change.changedHeight
    return change
  }

  /// The action for dropping a window at a point of the target window, from the target's center and edges.
  func resolveDrop(onto target: Window, at point: CGPoint) -> MouseDropAction {
    let f = target.frame
    let wp = CGPoint(x: point.x - f.minX, y: point.y - f.minY)
    let center = CGRect(
      x: 0.25 * f.width, y: 0.25 * f.height, width: 0.5 * f.width, height: 0.5 * f.height)
    let mid = CGPoint(x: 0.5 * f.width, y: 0.5 * f.height)
    let top = [CGPoint.zero, mid, CGPoint(x: f.width, y: 0)]
    let right = [CGPoint(x: f.width, y: 0), mid, CGPoint(x: f.width, y: f.height)]
    let bottom = [CGPoint(x: f.width, y: f.height), mid, CGPoint(x: 0, y: f.height)]
    let left = [CGPoint(x: 0, y: f.height), mid, CGPoint.zero]
    if center.contains(wp) { return Config.current.mouse.dropAction == .stack ? .stack : .swap }
    if wp.isInTriangle(top) { return .warpTop }
    if wp.isInTriangle(right) { return .warpRight }
    if wp.isInTriangle(bottom) { return .warpBottom }
    if wp.isInTriangle(left) { return .warpLeft }
    return .none
  }

  @WM func clearFeedback() {
    guard let feedbackWid = feedbackWindowID else { return }
    let wm = WindowManager.shared
    let target = wm.window(for: feedbackWid)
    let targetView = target.flatMap { wm.managedView(for: $0) }
    if let con = container(of: target, in: targetView), con.insertDirection == nil {
      con.hideFeedback()
    }
    feedbackWindowID = nil
    feedbackDirection = nil
  }

  //
  // NOTE: While a window is dragged over a managed window, the half where it would be placed
  // is outlined, or the whole window when dropping would swap or stack them.
  //

  @WM func showDropFeedback(view: View?, window: Window?, at point: CGPoint) {
    guard let con = container(of: window, in: view), let window else {
      clearFeedback()
      return
    }
    let direction = resolveDrop(onto: window, at: point).insertDirection
    if feedbackWindowID == window.id && feedbackDirection == direction { return }
    clearFeedback()
    guard let direction else { return }
    con.showFeedback(direction: direction)
    feedbackWindowID = window.id
    feedbackDirection = direction
  }

  @WM private func dropWithoutTarget(_ target: Window, from srcView: View, to dstView: View) {
    if srcView.sid == dstView.sid || dstView.layout == .float {
      srcView.flush()
      return
    }
    let wm = WindowManager.shared
    wm.unmanageWindow(target, from: srcView)
    wm.manageWindow(target, on: dstView.sid, inserting: nil)
  }

  //
  // NOTE: Dropping a window on a managed window: the center swaps the two windows, or makes
  // the dropped window a tab of the other one with mouse_drop_action stack. The edges place the dropped
  // window on that side of the other window.
  //

  @WM func drop(
    _ srcWindow: Window, from srcView: View, onto dstWindow: Window?, in dstView: View?,
    at point: CGPoint
  ) {
    clearFeedback()
    let wm = WindowManager.shared
    guard let dstView else {
      srcView.flush()
      return
    }
    guard let dstCon = container(of: dstWindow, in: dstView), let dstWindow else {
      dropWithoutTarget(srcWindow, from: srcView, to: dstView)
      return
    }
    let action = resolveDrop(onto: dstWindow, at: point)
    let direction = action.insertDirection
    if action == .none {
      srcView.flush()
    } else if action == .swap {
      try? wm.swapWindow(srcWindow, dstWindow)
    } else if direction == .stack {
      try? wm.stackWindow(dstWindow, srcWindow)
      if srcView != dstView { srcView.flush() }
    } else if srcView == dstView {
      // NOTE: every action other than none, swap and stack is a warp to a side, so direction is set
      guard let container = srcView.tree?.find(srcWindow.id), let direction else { return }
      container.detach()
      dstCon.insert(container, toward: direction)
      container.focus()
      srcView.tree!.flatten()
      if !srcView.updateAutoPadding() { srcView.updateTree() }
      srcView.flush()
    } else {
      dstCon.insertDirection = direction
      dstView.insertionPoint = dstWindow.id
      wm.unmanageWindow(srcWindow, from: srcView)
      wm.manageWindow(srcWindow, on: dstView.sid, inserting: nil)
    }
  }

  @WM private func container(of window: Window?, in view: View?) -> Con? {
    guard let view, let window else { return nil }
    return view.findWindow(window.id)
  }

  //
  // NOTE: The main run-loop tap receives its dedicated state unretained; MouseState.shared retains it for daemon lifetime.
  //

  @discardableResult
  func beginEventTap(mask: UInt32) -> Bool {
    if tap.hasPort { return true }
    let moveMask = UInt32(1 << CGEventType.mouseMoved.rawValue)
    guard
      let port = CGEvent.tapCreate(
        tap: .cghidEventTap, place: .headInsertEventTap, options: .defaultTap,
        eventsOfInterest: CGEventMask(mask | moveMask), callback: mouseHandler,
        userInfo: Unmanaged.passUnretained(tap).toOpaque())
    else { return false }
    tap.tracksFocus.store(mask & moveMask != 0, ordering: .relaxed)
    tap.retainPort(port)
    if !CGEvent.tapIsEnabled(tap: port) {
      tap.endEventTap {}
      return false
    }
    let source = CFMachPortCreateRunLoopSource(nil, port, 0)!
    runLoopSource = source
    CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
    return true
  }

  func endEventTap() {
    tap.endEventTap {
      guard let runLoopSource else { return }
      CFRunLoopRemoveSource(CFRunLoopGetMain(), runLoopSource, .commonModes)
      self.runLoopSource = nil
    }
  }
}

extension MouseDropAction {
  /// The direction a window is inserted toward when it is dropped with this action, or nil when nothing is dropped.
  var insertDirection: InsertDirection? {
    switch self {
    case .stack, .swap: .stack
    case .warpTop: .north
    case .warpRight: .east
    case .warpBottom: .south
    case .warpLeft: .west
    case .none: nil
    }
  }
}

extension WindowManager {
  /// Resizes the windows that the edges of a dragged window moved, and flushes the view when a resize fails.
  @WM func resizeAfterDrag(_ target: Window, in targetView: View, by change: MouseWindowChange) {
    var success = true
    if change.changedPosition {
      var direction: ResizeHandle = []
      if change.changedX { direction.insert(.left) }
      if change.changedY { direction.insert(.top) }
      do {
        try resizeWindow(target, direction: direction, dx: change.dx, dy: change.dy, animate: true)
      } catch .invalidDestinationNode {
        success = false
      } catch {}
    }
    if change.changedSize {
      var direction: ResizeHandle = []
      if change.changedWidth && !change.changedX { direction.insert(.right) }
      if change.changedHeight && !change.changedY { direction.insert(.bottom) }
      do {
        try resizeWindow(target, direction: direction, dx: change.dw, dy: change.dh, animate: true)
      } catch .invalidDestinationNode {
        success = false
      } catch {}
    }
    if !success { targetView.flush() }
  }
}
