import Darwin
import AppKit
import CPrivate
import YabaiCore

//
// NOTE: The handler of the window domain. Its commands are grouped by what they change: the lifecycle
// of a window, its placement, its tree container, its frame and its properties.
//

/// The commands and arguments of the window domain (`COMMAND_WINDOW_*` and `ARGUMENT_WINDOW_*`, src/message_parse.c).
private enum WindowCommand
{
    static let focus      = "--focus"
    static let close      = "--close"
    static let minimize   = "--minimize"
    static let deminimize = "--deminimize"
    static let display    = "--display"
    static let space      = "--space"
    static let swap       = "--swap"
    static let warp       = "--warp"
    static let stack      = "--stack"
    static let insert     = "--insert"
    static let grid       = "--grid"
    static let move       = "--move"
    static let resize     = "--resize"
    static let ratio      = "--ratio"
    static let subLayer   = "--sub-layer"
    static let opacity    = "--opacity"
    static let raise      = "--raise"
    static let lower      = "--lower"
    static let toggle     = "--toggle"
    static let scratchpad = "--scratchpad"
    static let layout     = "--layout"
    static let split      = "--split"

    static let moveFormat   = "%255[^:]:%f:%f"
    static let resizeFormat = "%255[^:]:%f:%f"
    static let ratioFormat  = "%255[^:]:%f"
}

/// Throws the failure of a window command whose acting or selected window is not managed; the command words the
/// other errors or does not report them.
private func checkManaged(_ error: WindowOperationError) throws(CommandError)
{
    switch error {
    case .invalidSourceView, .invalidSourceNode:           throw CommandError("the acting window is not managed.\n")
    case .invalidDestinationView, .invalidDestinationNode: throw CommandError("the selected window is not managed.\n")
    default:                                               break
    }
}

@WM private func windowTreeFocus(_ window: Window?, _ focus: TreeFocus) throws(WindowOperationError)
{
    let wm = WindowManager.shared
    switch focus {
    case .parent:                   try wm.treeFocusParent(for: window)
    case .child:                    try wm.treeFocusChild(for: window)
    case .direction(let direction): try wm.treeFocus(direction: direction, for: window)
    }
}

/// `parse_window_layout`
func parseWindowLayout(_ value: Token) -> WindowLayout?
{
    WindowLayout(value)
}

/// `parse_split_orientation`
func parseSplitOrientation(_ value: Token) -> SplitOrientation?
{
    SplitOrientation(value)
}

/// `window_toggle_list`: what a value of `window --toggle` that is a window property does.
@WM private func windowToggle(_ toggle: WindowToggle, _ window: Window)
{
    let sm = SpaceManager.shared
    let wm = WindowManager.shared

    switch toggle {
    case .float:              wm.makeWindowFloating(window, shouldFloat: !window.isFloating, force: false)
    case .sticky:             wm.makeWindowSticky(window, shouldBeSticky: !window.isSticky)
    case .shadow:             window.toggleShadow()
    case .split:              sm.toggleSplit(of: window)
    case .zoomParent:         wm.toggleParentZoom(window)
    case .zoomFullscreen:     wm.toggleFullscreenZoom(window)
    case .windowedFullscreen: wm.toggleWindowedFullscreen(window)
    case .nativeFullscreen:   wm.toggleNativeFullscreen(window)
    case .expose:             wm.toggleExpose(window)
    case .pip:                wm.togglePictureInPicture(window)
    }
}

//
// NOTE: Focusing, closing, minimizing and deminimizing windows.
//

@WM private func windowCommandLifecycle(_ command: Token, _ message: inout some TokenSource, _ actingWindow: inout Window?) throws(CommandError) -> CommandResult
{
    let context = CSelectorContext()

    if command.equals(WindowCommand.focus) {
        let treeFocus = WindowManager.shared.treeView(for: actingWindow) != nil ? TreeFocus(message.peek()) : nil
        if let treeFocus {
            _ = message.next()

            do {
                try windowTreeFocus(actingWindow, treeFocus)
            } catch {
                throw CommandError("could not locate a container to focus.\n", stopsMessage: true)
            }

            return .done
        }

        do {
            if !(try parseOptionalWindowSelector(&message, &actingWindow, context)) { return .stop }
        } catch {
            throw error.stoppingMessage
        }

        if let window = actingWindow {
            WindowManager.shared.focusWithRaise(window)
            WindowManager.shared.setPendingFocus(window.id)
        } else {
            throw CommandError("could not locate the window to act on!\n")
        }
    } else if command.equals(WindowCommand.close) {
        do {
            if !(try parseOptionalWindowSelector(&message, &actingWindow, context)) { return .stop }
        } catch {
            throw error.stoppingMessage
        }

        if let window = actingWindow {
            if !window.close() {
                throw CommandError("could not close window with id '\(Int32(bitPattern: window.id.rawValue))'.\n")
            }
        } else {
            throw CommandError("could not locate the window to act on!\n")
        }
    } else if command.equals(WindowCommand.minimize) {
        do {
            if !(try parseOptionalWindowSelector(&message, &actingWindow, context)) { return .stop }
        } catch {
            throw error.stoppingMessage
        }

        if let window = actingWindow {
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
        } else {
            throw CommandError("could not locate the window to act on!\n")
        }
    } else if command.equals(WindowCommand.deminimize) {
        let selector = try parseWindowSelector(message.next(), acting: actingWindow, optional: false, context).checked()
        if selector.didParse, let window = selector.value {
            let id = Int32(bitPattern: window.id.rawValue)
            do {
                try window.deminimize()
            } catch .notMinimized {
                throw CommandError("window with id '\(id)' is not minimized.\n")
            } catch .deminimizeFailed {
                throw CommandError("could not deminimize window with id '\(id)'.\n")
            } catch {}
        }
    } else {
        return .unknown
    }

    return .done
}

//
// NOTE: Moving a window to another display, space or position in the tree.
//

@WM private func windowCommandPlacement(_ command: Token, _ message: inout some TokenSource, _ actingWindow: Window) throws(CommandError) -> CommandResult
{
    let wm = WindowManager.shared
    let context = CSelectorContext()

    if command.equals(WindowCommand.display) {
        let selector = try parseDisplaySelector(message.next(), acting: DisplayID.active, optional: false, context).checked()
        if selector.didParse, let target = selector.value {
            if let sid = target.currentSpace {
                if sid.isFullscreen {
                    throw CommandError("can not move window to a macOS fullscreen space!\n")
                } else {
                    wm.sendWindow(actingWindow, to: sid, movedByRule: false)
                }
            } else {
                throw CommandError("could not locate the space to act on.\n")
            }
        }
    } else if command.equals(WindowCommand.space) {
        let selector = try parseSpaceSelector(message.next(), acting: SpaceID.active, optional: false, context).checked()
        if selector.didParse, let target = selector.value {
            if target.isFullscreen {
                throw CommandError("can not move window to a macOS fullscreen space!\n")
            } else {
                wm.sendWindow(actingWindow, to: target, movedByRule: false)
            }
        }
    } else if command.equals(WindowCommand.swap) {
        let selector = try parseWindowSelector(message.next(), acting: actingWindow, optional: false, context).checked()
        if selector.didParse, let window = selector.value {
            do {
                try wm.swapWindow(actingWindow, window)
            } catch .sameWindow {
                throw CommandError("cannot swap a window with itself.\n")
            } catch {
                try checkManaged(error)
            }
        }
    } else if command.equals(WindowCommand.warp) {
        if wm.treeView(for: actingWindow) != nil, case .direction(let direction) = TreeFocus(message.peek()) {
            _ = message.next()

            do {
                try wm.treeMove(direction: direction, for: actingWindow)
            } catch {
                throw CommandError("could not move the container in that direction.\n", stopsMessage: true)
            }

            return .done
        }

        let selector = try parseWindowSelector(message.next(), acting: actingWindow, optional: false, context).checked()
        if selector.didParse, let window = selector.value {
            do {
                try wm.warpWindow(actingWindow, window)
            } catch .sameWindow {
                throw CommandError("cannot warp a window onto itself.\n")
            } catch {
                try checkManaged(error)
            }
        }
    } else if command.equals(WindowCommand.stack) {
        let selector = try parseWindowSelector(message.next(), acting: actingWindow, optional: false, context).checked()
        if selector.didParse, let window = selector.value {
            do {
                try wm.stackWindow(actingWindow, window)
            } catch .sameWindow {
                throw CommandError("cannot stack a window onto itself.\n")
            } catch {
                try checkManaged(error)
            }
        }
    } else {
        return .unknown
    }

    return .done
}

//
// NOTE: The container of a window in the tree.
//

@WM func windowCommandTree(_ domain: Token, _ command: Token, _ message: inout some TokenSource, _ actingWindow: Window?) throws(CommandError) -> CommandResult
{
    let wm = WindowManager.shared

    if command.equals(WindowCommand.layout) {
        let value = message.next()
        guard let layout = parseWindowLayout(value) else {
            throw CommandError.unknownValue(domain, command, value).stoppingMessage
        }

        do {
            try wm.setWindowLayout(actingWindow, layout)
        } catch {
            try checkManaged(error)
        }
    } else if command.equals(WindowCommand.split) {
        let value = message.next()
        guard let orientation = parseSplitOrientation(value) else {
            throw CommandError.unknownValue(domain, command, value).stoppingMessage
        }

        do {
            try wm.treeSplit(orientation, for: actingWindow)
        } catch {
            try checkManaged(error)
        }
    } else if command.equals(WindowCommand.insert) {
        let direction = try parseInsertSelector(message.next())
        do {
            try wm.setWindowInsertion(actingWindow, direction)
        } catch {
            try checkManaged(error)
        }
    } else {
        return .unknown
    }

    return .done
}

//
// NOTE: The frame of a floating window and the share of a tiled one.
//

@WM private func windowCommandFrame(_ domain: Token, _ command: Token, _ message: inout some TokenSource, _ actingWindow: Window) throws(CommandError) -> CommandResult
{
    let wm = WindowManager.shared

    if command.equals(WindowCommand.grid) {
        var grid = Grid()
        let value = message.next()
        if grid.scan(value) == 6 {
            do {
                try wm.applyGrid(grid, to: actingWindow)
            } catch .invalidSourceView {
                throw CommandError("cannot apply grid layout to a managed window.\n")
            } catch {}
        } else {
            throw CommandError.unknownValue(domain, command, value)
        }
    } else if command.equals(WindowCommand.move) {
        var type: [CChar] = []
        var point: [Float] = [0, 0]
        let value = message.next()
        if value.scan(WindowCommand.moveFormat, &type, &point) == 3 {
            do {
                try wm.moveWindow(actingWindow, type: valueType(type), dx: point[0], dy: point[1])
            } catch .invalidSourceView {
                throw CommandError("cannot move a managed window.\n")
            } catch {}
        } else {
            throw CommandError.unknownValue(domain, command, value)
        }
    } else if command.equals(WindowCommand.resize) {
        var handle: [CChar] = []
        var size: [Float] = [0, 0]
        let value = message.next()
        if value.scan(WindowCommand.resizeFormat, &handle, &size) == 3 {
            do {
                try wm.resizeWindow(actingWindow, direction: parseResizeHandle(Token(cString: handle)), dx: size[0], dy: size[1], animate: true)
            } catch .invalidSourceNode {
                throw CommandError("cannot locate the container of the managed window.\n")
            } catch .invalidDestinationNode {
                throw CommandError("cannot resize the container in that direction.\n")
            } catch .invalidOperation {
                throw CommandError("cannot use absolute resizing on a managed window.\n")
            } catch {}
        } else {
            throw CommandError.unknownValue(domain, command, value)
        }
    } else if command.equals(WindowCommand.ratio) {
        var type: [CChar] = []
        var ratio: [Float] = [0]
        let value = message.next()
        if value.scan(WindowCommand.ratioFormat, &type, &ratio) == 2 {
            do {
                try wm.adjustWindowRatio(for: actingWindow, type: valueType(type), ratio: ratio[0])
            } catch .invalidSourceView {
                throw CommandError("cannot adjust ratio of a non-managed window.\n")
            } catch .invalidSourceNode {
                throw CommandError("cannot adjust ratio of a root node.\n")
            } catch {}
        } else {
            throw CommandError.unknownValue(domain, command, value)
        }
    } else {
        return .unknown
    }

    return .done
}

//
// NOTE: Window properties: toggles, layer, opacity, order and scratchpads.
//

@WM private func windowCommandProperty(_ domain: Token, _ command: Token, _ message: inout some TokenSource, _ actingWindow: Window?) throws(CommandError) -> CommandResult
{
    let wm = WindowManager.shared

    if command.equals(WindowCommand.toggle) {
        //
        // NOTE: A value that is not a window property is a scratchpad label.
        //

        let value = message.next()
        if let toggle = WindowToggle(value) {
            if let window = actingWindow {
                windowToggle(toggle, window)
            } else {
                throw CommandError("could not locate the window to act on!\n")
            }
        } else if !wm.toggleScratchpad(withLabel: value.string) {
            throw CommandError.unknownValue(domain, command, value)
        }
        return .done
    }

    guard let actingWindow else { return .unknown }
    let id = Int32(bitPattern: actingWindow.id.rawValue)

    if command.equals(WindowCommand.subLayer) {
        let value = message.next()
        if let layer = parseLayer(value) {
            if !wm.setWindowLayer(actingWindow, to: layer) {
                throw CommandError("could not change sub-layer of window with id '\(id)' due to an error with the scripting-addition.\n")
            }
        } else {
            throw CommandError.unknownValue(domain, command, value)
        }
    } else if command.equals(WindowCommand.opacity) {
        let token = message.next()
        if let opacity = token.value.floatValue, opacity >= 0.0 && opacity <= 1.0 {
            if wm.setOpacity(for: actingWindow, to: opacity) {
                actingWindow.opacity = opacity
            } else {
                throw CommandError("could not change opacity of window with id '\(id)' due to an error with the scripting-addition.\n")
            }
        } else {
            throw CommandError.unknownValue(domain, command, token)
        }
    } else if command.equals(WindowCommand.raise) || command.equals(WindowCommand.lower) {
        let raise = command.equals(WindowCommand.raise)
        let selector = parseWindowSelector(message.next(), acting: actingWindow, optional: true, CSelectorContext())
        var relativeWid: WindowID?

        if selector.token.isValid {
            if let failure = selector.failure { throw failure.stoppingMessage }
            guard selector.didParse, let window = selector.value else { return .stop }
            relativeWid = window.id
        }

        if !ScriptingAddition.shared.orderWindow(actingWindow.id, raise ? 1 : -1, relativeTo: relativeWid) {
            throw CommandError("could not \(raise ? "raise" : "lower") window with id '\(id)' due to an error with the scripting-addition.\n")
        }
    } else if command.equals(WindowCommand.scratchpad) {
        let token = message.next()
        if token.isValid && token.equals(Argument.recover) {
            wm.recoverScratchpadWindows()
        } else if let label = try parseLabel(token, .window) {
            if !wm.setScratchpad(for: actingWindow, label: label.string) {
                throw CommandError("the given scratchpad is already assigned to a different window!\n")
            }
        } else if !wm.removeScratchpad(from: actingWindow, unfloat: true) {
            throw CommandError("the selected window was not assigned to a scratchpad!\n")
        }
    } else {
        return .unknown
    }

    return .done
}

@WM func handleDomainWindow(_ rsp: inout Response, _ domain: Token, _ message: inout some TokenSource) throws(CommandError)
{
    let command: Token
    var actingWindow: Window? = WindowManager.shared.actingWindow
    let selector = parseWindowSelector(message.next(), acting: actingWindow, optional: true, CSelectorContext())

    if selector.didParse {
        actingWindow = selector.value
        command = message.next()
    } else {
        command = selector.token
    }

    try runCommands(&rsp, &message, from: command) { (_, source, command) throws(CommandError) -> CommandResult in
        if actingWindow == nil &&
           !command.equals(WindowCommand.focus) &&
           !command.equals(WindowCommand.close) &&
           !command.equals(WindowCommand.minimize) &&
           !command.equals(WindowCommand.deminimize) &&
           !command.equals(WindowCommand.toggle) {
            throw CommandError("could not locate the window to act on!\n", stopsMessage: true)
        }

        var result = try windowCommandLifecycle(command, &source, &actingWindow)
        if result == .unknown, let window = actingWindow { result = try windowCommandPlacement(command, &source, window) }
        if result == .unknown { result = try windowCommandTree(domain, command, &source, actingWindow) }
        if result == .unknown, let window = actingWindow { result = try windowCommandFrame(domain, command, &source, window) }
        if result == .unknown { result = try windowCommandProperty(domain, command, &source, actingWindow) }
        if result == .unknown { throw CommandError.unknownCommand(domain, command) }

        return result
    }
}
