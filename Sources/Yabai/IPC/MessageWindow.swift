import AppKit
import CPrivate
import Darwin
import YabaiCore

//
// NOTE: The handler of the window domain. YabaiCore parses each command into a WindowCommand; it runs here against the
// acting window, grouped by what it changes: the lifecycle of a window, its placement, its tree container, its frame
// and its properties.
//

/// The failure of a command when there is no window to act on.
private let noActingWindow = CommandError("could not locate the window to act on!\n")

/// Throws the failure of a window command whose acting or selected window is not managed; the command words the
/// other errors or does not report them.
private func checkManaged(_ error: WindowOperationError) throws(CommandError) {
  switch error {
  case .invalidSourceView, .invalidSourceNode:
    throw CommandError("the acting window is not managed.\n")
  case .invalidDestinationView, .invalidDestinationNode:
    throw CommandError("the selected window is not managed.\n")
  default: break
  }
}

/// Makes the window that a selector selects the acting window and returns it; without a selector, returns the acting
/// window. A failing selector stops the message.
@WM private func selectActingWindow(
  _ selector: WindowSelector?, _ acting: inout Window?, _ context: CSelectorContext
) throws(CommandError) -> Window {
  if let selector {
    do {
      acting = try selector.resolve(acting: acting, context)
    } catch {
      throw error.stoppingMessage
    }
  }

  guard let window = acting else { throw noActingWindow }
  return window
}

extension WindowManager {
  /// Focuses the container of the tree that `window --focus` selects from the window.
  fileprivate func focusContainer(_ focus: TreeFocus, for window: Window?)
    throws(WindowOperationError)
  {
    switch focus {
    case .parent: try treeFocusParent(for: window)
    case .child: try treeFocusChild(for: window)
    case .direction(let direction): try treeFocus(direction: direction, for: window)
    }
  }
}

extension WindowToggle {
  /// Toggles the window property on the window.
  @WM fileprivate func apply(to window: Window) {
    let sm = SpaceManager.shared
    let wm = WindowManager.shared

    switch self {
    case .float: wm.makeWindowFloating(window, shouldFloat: !window.isFloating, force: false)
    case .sticky: wm.makeWindowSticky(window, shouldBeSticky: !window.isSticky)
    case .shadow: window.toggleShadow()
    case .split: sm.toggleSplit(of: window)
    case .zoomParent: wm.toggleParentZoom(window)
    case .zoomFullscreen: wm.toggleFullscreenZoom(window)
    case .windowedFullscreen: wm.toggleWindowedFullscreen(window)
    case .nativeFullscreen: wm.toggleNativeFullscreen(window)
    case .expose: wm.toggleExpose(window)
    case .pip: wm.togglePictureInPicture(window)
    }
  }
}

extension WindowCommand {
  /// Runs the command. A focus, close or minimize with a selector makes the selected window the acting window of the
  /// commands that follow it in the message.
  @WM func run(acting: inout Window?) throws(CommandError) {
    switch self {
    case .focus, .close, .minimize, .deminimize:
      try runLifecycle(acting: &acting)
    case .toggle(let toggle):
      guard let window = acting else { throw noActingWindow }
      toggle.apply(to: window)
    case .toggleScratchpad(let label):
      if !WindowManager.shared.toggleScratchpad(withLabel: label.string) {
        throw WindowCommand.unknownValue(
          .toggle, label,
          expected: expectedChoices(WindowToggle.allCases.map(\.rawValue))
            + ", or the label of a scratchpad")
      }
    case .display, .space, .swap, .warp, .stack:
      try runPlacement(on: try requiredWindow(acting))
    case .layout, .split, .insert:
      try runTree(on: try requiredWindow(acting))
    case .grid, .move, .resize, .ratio:
      try runFrame(on: try requiredWindow(acting))
    case .subLayer, .opacity, .raise, .lower, .scratchpad:
      try runProperty(on: try requiredWindow(acting))
    }
  }

  //
  // NOTE: handleDomainWindow fails the commands that need a window before parsing them when there is none, so this
  // only guards the commands run on their own.
  //

  private func requiredWindow(_ acting: Window?) throws(CommandError) -> Window {
    guard let acting else { throw noActingWindow.stoppingMessage }
    return acting
  }

  //
  // NOTE: Focusing, closing, minimizing and deminimizing windows.
  //

  @WM private func runLifecycle(acting: inout Window?) throws(CommandError) {
    let wm = WindowManager.shared
    let context = CSelectorContext()

    switch self {
    case .focus(.container(let focus)) where wm.treeView(for: acting) != nil:
      do {
        try wm.focusContainer(focus, for: acting)
      } catch {
        throw CommandError("could not locate a container to focus.\n", stopsMessage: true)
      }
    case .focus(let target):
      let selector: WindowSelector?
      do {
        selector = try target.windowSelector()
      } catch {
        throw error.stoppingMessage
      }

      let window = try selectActingWindow(selector, &acting, context)
      wm.focusWithRaise(window)
      wm.setPendingFocus(window.id)
    case .close(let selector):
      let window = try selectActingWindow(selector, &acting, context)
      if !window.close() {
        throw CommandError(
          "could not close window with id '\(Int32(bitPattern: window.id.rawValue))'.\n")
      }
    case .minimize(let selector):
      let window = try selectActingWindow(selector, &acting, context)
      let id = Int32(bitPattern: window.id.rawValue)
      do {
        try window.minimize()
      } catch .cannotMinimize {
        throw CommandError("window with id '\(id)' does not support the minimize operation.\n")
      } catch .alreadyMinimized {
        throw CommandError("window with id '\(id)' is already minimized.\n")
      } catch .minimizeFailed {
        throw CommandError("could not minimize window with id '\(id)'.\n")
      } catch {}
    case .deminimize(let selector):
      let window = try selector.resolve(acting: acting, context)
      let id = Int32(bitPattern: window.id.rawValue)
      do {
        try window.deminimize()
      } catch .notMinimized {
        throw CommandError("window with id '\(id)' is not minimized.\n")
      } catch .deminimizeFailed {
        throw CommandError("could not deminimize window with id '\(id)'.\n")
      } catch {}
    default:
      break
    }
  }

  //
  // NOTE: Moving a window to another display, space or position in the tree. A 'recent' display or space that
  // finds nothing does nothing.
  //

  @WM private func runPlacement(on window: Window) throws(CommandError) {
    let wm = WindowManager.shared
    let context = CSelectorContext()

    switch self {
    case .display(let selector):
      guard let did = try selector.resolve(acting: DisplayID.active, context) else { return }
      guard let sid = did.currentSpace else {
        throw CommandError("could not locate the space to act on.\n")
      }
      if sid.isFullscreen {
        throw CommandError("can not move window to a macOS fullscreen space!\n")
      }
      wm.sendWindow(window, to: sid, movedByRule: false)
    case .space(let selector):
      guard let sid = try selector.resolve(acting: SpaceID.active, context) else { return }
      if sid.isFullscreen {
        throw CommandError("can not move window to a macOS fullscreen space!\n")
      }
      wm.sendWindow(window, to: sid, movedByRule: false)
    case .swap(let selector):
      let target = try selector.resolve(acting: window, context)
      do {
        try wm.swapWindow(window, target)
      } catch .sameWindow {
        throw CommandError("cannot swap a window with itself.\n")
      } catch {
        try checkManaged(error)
      }
    case .warp(.direction(let direction)) where wm.treeView(for: window) != nil:
      do {
        try wm.treeMove(direction: direction, for: window)
      } catch {
        throw CommandError("could not move the container in that direction.\n", stopsMessage: true)
      }
    case .warp(let selector):
      let target = try selector.resolve(acting: window, context)
      do {
        try wm.warpWindow(window, target)
      } catch .sameWindow {
        throw CommandError("cannot warp a window onto itself.\n")
      } catch {
        try checkManaged(error)
      }
    case .stack(let selector):
      let target = try selector.resolve(acting: window, context)
      do {
        try wm.stackWindow(window, target)
      } catch .sameWindow {
        throw CommandError("cannot stack a window onto itself.\n")
      } catch {
        try checkManaged(error)
      }
    default:
      break
    }
  }

  //
  // NOTE: The container of a window in the tree.
  //

  @WM private func runTree(on window: Window) throws(CommandError) {
    let wm = WindowManager.shared

    do {
      switch self {
      case .layout(let layout): try wm.setWindowLayout(window, layout)
      case .split(let orientation): try wm.treeSplit(orientation, for: window)
      case .insert(let direction): try wm.setWindowInsertion(window, direction)
      default: break
      }
    } catch {
      try checkManaged(error)
    }
  }

  //
  // NOTE: The frame of a floating window and the share of a tiled one.
  //

  @WM private func runFrame(on window: Window) throws(CommandError) {
    let wm = WindowManager.shared

    switch self {
    case .grid(let grid):
      do {
        try wm.applyGrid(grid, to: window)
      } catch .invalidSourceView {
        throw CommandError("cannot apply grid layout to a managed window.\n")
      } catch {}
    case .move(let type, let dx, let dy):
      do {
        try wm.moveWindow(window, type: type, dx: dx, dy: dy)
      } catch .invalidSourceView {
        throw CommandError("cannot move a managed window.\n")
      } catch {}
    case .resize(let handle, let dx, let dy):
      do {
        try wm.resizeWindow(window, direction: handle, dx: dx, dy: dy, animate: true)
      } catch .invalidSourceNode {
        throw CommandError("cannot locate the container of the managed window.\n")
      } catch .invalidDestinationNode {
        throw CommandError("cannot resize the container in that direction.\n")
      } catch .invalidOperation {
        throw CommandError("cannot use absolute resizing on a managed window.\n")
      } catch {}
    case .ratio(let type, let ratio):
      do {
        try wm.adjustWindowRatio(for: window, type: type, ratio: ratio)
      } catch .invalidSourceView {
        throw CommandError("cannot adjust ratio of a non-managed window.\n")
      } catch .invalidSourceNode {
        throw CommandError("cannot adjust ratio of a root node.\n")
      } catch {}
    default:
      break
    }
  }

  //
  // NOTE: Window properties: layer, opacity, order and scratchpads.
  //

  @WM private func runProperty(on window: Window) throws(CommandError) {
    let wm = WindowManager.shared
    let id = Int32(bitPattern: window.id.rawValue)

    switch self {
    case .subLayer(let layer):
      if !wm.setWindowLayer(window, to: layer) {
        throw CommandError(
          "could not change sub-layer of window with id '\(id)' due to an error with the scripting-addition.\n"
        )
      }
    case .opacity(let opacity):
      if wm.setOpacity(for: window, to: opacity) {
        window.opacity = opacity
      } else {
        throw CommandError(
          "could not change opacity of window with id '\(id)' due to an error with the scripting-addition.\n"
        )
      }
    case .raise(let selector):
      try order(window, raise: true, relativeTo: selector)
    case .lower(let selector):
      try order(window, raise: false, relativeTo: selector)
    case .scratchpad(.recover):
      wm.recoverScratchpadWindows()
    case .scratchpad(.assign(let label)):
      if !wm.setScratchpad(for: window, label: label) {
        throw CommandError("the given scratchpad is already assigned to a different window!\n")
      }
    case .scratchpad(.remove):
      if !wm.removeScratchpad(from: window, unfloat: true) {
        throw CommandError("the selected window was not assigned to a scratchpad!\n")
      }
    default:
      break
    }
  }

  /// Raises or lowers the window, above or below the window a selector selects; a failing selector stops the message.
  @WM private func order(_ window: Window, raise: Bool, relativeTo selector: WindowSelector?)
    throws(CommandError)
  {
    var relativeWid: WindowID?
    if let selector {
      do {
        relativeWid = try selector.resolve(acting: window, CSelectorContext()).id
      } catch {
        throw error.stoppingMessage
      }
    }

    if !ScriptingAddition.shared.orderWindow(window.id, raise ? 1 : -1, relativeTo: relativeWid) {
      throw CommandError(
        "could not \(raise ? "raise" : "lower") window with id '\(Int32(bitPattern: window.id.rawValue))' due to an error with the scripting-addition.\n"
      )
    }
  }
}

//
// NOTE: A leading window selector replaces the acting window, even when it finds none; a token that is no selector is
// the first command. Each command is parsed after the previous one ran, since it may have changed the acting window.
//

@WM func handleDomainWindow(
  _ rsp: inout Response, _ domain: Token, _ message: inout some TokenSource
) throws(CommandError) {
  var actingWindow: Window? = WindowManager.shared.actingWindow()
  var first = message.next()

  if let selector = WindowSelector(first) {
    actingWindow = try? selector.resolve(acting: actingWindow, CSelectorContext())
    first = message.next()
  }

  try runCommands(&rsp, &message, from: first) { (_, source, token) throws(CommandError) -> Bool in
    let name = WindowCommand.Name(token: token)
    if actingWindow == nil && name?.needsWindow != false {
      throw noActingWindow.stoppingMessage
    }
    guard let name else { throw CommandError.unknownCommand(domain, token) }

    try WindowCommand.parse(name, &source).run(acting: &actingWindow)
    return true
  }
}
