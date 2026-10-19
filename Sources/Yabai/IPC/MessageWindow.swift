import Darwin
import AppKit
import CPrivate
import YabaiCore

//
// NOTE: The handler of the window domain. Its commands are grouped by what they change: the lifecycle
// of a window, its placement, its tree container, its frame and its properties. Ported from src/message_window.c.
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

    static let splitHorizontal   = "horizontal"
    static let splitVertical     = "vertical"
    static let splitToggle       = "toggle"
}

extension Response
{
    mutating func failUnmanagedWindow(_ result: WindowOperationResult)
    {
        switch result {
        case .invalidSourceView, .invalidSourceNode:           fail("the acting window is not managed.\n")
        case .invalidDestinationView, .invalidDestinationNode: fail("the selected window is not managed.\n")
        default:                                               break
        }
    }
}

private func windowTreeFocus(_ window: Window?, _ focus: TreeFocus) -> WindowOperationResult
{
    let wm = window_manager_global()
    switch focus {
    case .parent:                   return wm.treeFocusParent(for: window)
    case .child:                    return wm.treeFocusChild(for: window)
    case .direction(let direction): return wm.treeFocus(direction: direction, for: window)
    }
}

/// `parse_window_layout`
func parseWindowLayout(_ value: Token) -> WindowLayout?
{
    WindowLayout.allCases.first { value.equals($0.rawValue) }
}

/// `parse_split_orientation`
func parseSplitOrientation(_ value: Token) -> SplitOrientation?
{
    if value.equals(WindowCommand.splitHorizontal) { return .fixed(.horizontal) }
    if value.equals(WindowCommand.splitVertical)   { return .fixed(.vertical) }
    if value.equals(WindowCommand.splitToggle)     { return .toggle }
    return nil
}

/// `window_toggle_list`: what a value of `window --toggle` that is a window property does.
private func windowToggle(_ toggle: WindowToggle, _ window: Window)
{
    let sm = space_manager_global()
    let wm = window_manager_global()

    switch toggle {
    case .float:              wm.makeWindowFloating(window, shouldFloat: !window.isFloating, force: false)
    case .sticky:             wm.makeWindowSticky(window, shouldBeSticky: !window.isSticky)
    case .shadow:             window.toggleShadow()
    case .split:              space_manager_toggle_window_split(sm, window)
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

private func windowCommandLifecycle(_ rsp: inout Response, _ command: Token, _ message: inout some TokenSource, _ actingWindow: inout Window?) -> CommandResult
{
    let context = CSelectorContext()

    if command.equals(WindowCommand.focus) {
        let treeFocus = WindowManager.shared.treeView(for: actingWindow) != nil ? parseTreeFocus(message.peek()) : nil
        if let treeFocus {
            _ = message.next()

            if windowTreeFocus(actingWindow, treeFocus) != .success {
                rsp.fail("could not locate a container to focus.\n")
                return .stop
            }

            return .done
        }

        if !parseOptionalWindowSelector(&rsp, &message, &actingWindow, context) { return .stop }

        if let window = actingWindow {
            window_manager_focus_window_with_raise(&window.application.psn, window.id, window.ref)
            window_manager_set_pending_focus(window_manager_global(), window.id)
        } else {
            rsp.fail("could not locate the window to act on!\n")
        }
    } else if command.equals(WindowCommand.close) {
        if !parseOptionalWindowSelector(&rsp, &message, &actingWindow, context) { return .stop }

        if let window = actingWindow {
            if !window.close() {
                rsp.fail("could not close window with id '\(Int32(bitPattern: window.id.rawValue))'.\n")
            }
        } else {
            rsp.fail("could not locate the window to act on!\n")
        }
    } else if command.equals(WindowCommand.minimize) {
        if !parseOptionalWindowSelector(&rsp, &message, &actingWindow, context) { return .stop }

        if let window = actingWindow {
            let id = Int32(bitPattern: window.id.rawValue)
            let result = window.minimize()
            if result == .cannotMinimize {
                rsp.fail("window with id '\(id)' does not support the minimize operation.\n")
            } else if result == .alreadyMinimized {
                rsp.fail("window with id '\(id)' is already minimized.\n")
            } else if result == .minimizeFailed {
                rsp.fail("could not minimize window with id '\(id)'.\n")
            }
        } else {
            rsp.fail("could not locate the window to act on!\n")
        }
    } else if command.equals(WindowCommand.deminimize) {
        let selector = parseWindowSelector(&rsp, message.next(), acting: actingWindow, optional: false, context)
        if selector.didParse, let window = selector.value {
            let id = Int32(bitPattern: window.id.rawValue)
            let result = window.deminimize()
            if result == .notMinimized {
                rsp.fail("window with id '\(id)' is not minimized.\n")
            } else if result == .deminimizeFailed {
                rsp.fail("could not deminimize window with id '\(id)'.\n")
            }
        }
    } else {
        return .unknown
    }

    return .done
}

//
// NOTE: Moving a window to another display, space or position in the tree.
//

private func windowCommandPlacement(_ rsp: inout Response, _ command: Token, _ message: inout some TokenSource, _ actingWindow: Window) -> CommandResult
{
    let wm = window_manager_global()
    let context = CSelectorContext()

    if command.equals(WindowCommand.display) {
        let selector = parseDisplaySelector(&rsp, message.next(), acting: display_manager_active_display_id(), optional: false, context)
        if selector.didParse, let target = selector.value {
            if let sid = display_space_id(target) {
                if space_is_fullscreen(sid) {
                    rsp.fail("can not move window to a macOS fullscreen space!\n")
                } else {
                    wm.sendWindow(actingWindow, to: sid, movedByRule: false)
                }
            } else {
                rsp.fail("could not locate the space to act on.\n")
            }
        }
    } else if command.equals(WindowCommand.space) {
        let selector = parseSpaceSelector(&rsp, message.next(), acting: space_manager_active_space(), optional: false, context)
        if selector.didParse, let target = selector.value {
            if space_is_fullscreen(target) {
                rsp.fail("can not move window to a macOS fullscreen space!\n")
            } else {
                wm.sendWindow(actingWindow, to: target, movedByRule: false)
            }
        }
    } else if command.equals(WindowCommand.swap) {
        let selector = parseWindowSelector(&rsp, message.next(), acting: actingWindow, optional: false, context)
        if selector.didParse, let window = selector.value {
            let result = wm.swapWindow(actingWindow, window)
            if result == .sameWindow {
                rsp.fail("cannot swap a window with itself.\n")
            } else {
                rsp.failUnmanagedWindow(result)
            }
        }
    } else if command.equals(WindowCommand.warp) {
        if wm.treeView(for: actingWindow) != nil, case .direction(let direction) = parseTreeFocus(message.peek()) {
            _ = message.next()

            if wm.treeMove(direction: direction, for: actingWindow) != .success {
                rsp.fail("could not move the container in that direction.\n")
                return .stop
            }

            return .done
        }

        let selector = parseWindowSelector(&rsp, message.next(), acting: actingWindow, optional: false, context)
        if selector.didParse, let window = selector.value {
            let result = wm.warpWindow(actingWindow, window)
            if result == .sameWindow {
                rsp.fail("cannot warp a window onto itself.\n")
            } else {
                rsp.failUnmanagedWindow(result)
            }
        }
    } else if command.equals(WindowCommand.stack) {
        let selector = parseWindowSelector(&rsp, message.next(), acting: actingWindow, optional: false, context)
        if selector.didParse, let window = selector.value {
            let result = wm.stackWindow(actingWindow, window)
            if result == .sameWindow {
                rsp.fail("cannot stack a window onto itself.\n")
            } else {
                rsp.failUnmanagedWindow(result)
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

func windowCommandTree(_ rsp: inout Response, _ domain: Token, _ command: Token, _ message: inout some TokenSource, _ actingWindow: Window?) -> CommandResult
{
    let wm = window_manager_global()

    if command.equals(WindowCommand.layout) {
        let value = message.next()
        guard let layout = parseWindowLayout(value) else {
            rsp.failUnknownValue(domain, command, value)
            return .stop
        }

        rsp.failUnmanagedWindow(wm.setWindowLayout(actingWindow, layout))
    } else if command.equals(WindowCommand.split) {
        let value = message.next()
        guard let orientation = parseSplitOrientation(value) else {
            rsp.failUnknownValue(domain, command, value)
            return .stop
        }

        rsp.failUnmanagedWindow(wm.treeSplit(orientation, for: actingWindow))
    } else if command.equals(WindowCommand.insert) {
        let selector = parseInsertSelector(&rsp, message.next())
        if selector.didParse, let direction = selector.value {
            rsp.failUnmanagedWindow(wm.setWindowInsertion(actingWindow, direction))
        }
    } else {
        return .unknown
    }

    return .done
}

//
// NOTE: The frame of a floating window and the share of a tiled one.
//

private func windowCommandFrame(_ rsp: inout Response, _ domain: Token, _ command: Token, _ message: inout some TokenSource, _ actingWindow: Window) -> CommandResult
{
    let wm = window_manager_global()

    if command.equals(WindowCommand.grid) {
        var grid = Grid()
        let value = message.next()
        if grid.scan(value) == 6 {
            let result = wm.applyGrid(grid, to: actingWindow)
            if result == .invalidSourceView {
                rsp.fail("cannot apply grid layout to a managed window.\n")
            }
        } else {
            rsp.failUnknownValue(domain, command, value)
        }
    } else if command.equals(WindowCommand.move) {
        var type: [CChar] = []
        var point: [Float] = [0, 0]
        let value = message.next()
        if value.scan(WindowCommand.moveFormat, &type, &point) == 3 {
            let result = wm.moveWindow(actingWindow, type: valueType(type), dx: point[0], dy: point[1])
            if result == .invalidSourceView {
                rsp.fail("cannot move a managed window.\n")
            }
        } else {
            rsp.failUnknownValue(domain, command, value)
        }
    } else if command.equals(WindowCommand.resize) {
        var handle: [CChar] = []
        var size: [Float] = [0, 0]
        let value = message.next()
        if value.scan(WindowCommand.resizeFormat, &handle, &size) == 3 {
            let result = wm.resizeWindow(actingWindow, direction: parseResizeHandle(Token(cString: handle)), dx: size[0], dy: size[1], animate: true)
            if result == .invalidSourceNode {
                rsp.fail("cannot locate the container of the managed window.\n")
            } else if result == .invalidDestinationNode {
                rsp.fail("cannot resize the container in that direction.\n")
            } else if result == .invalidOperation {
                rsp.fail("cannot use absolute resizing on a managed window.\n")
            }
        } else {
            rsp.failUnknownValue(domain, command, value)
        }
    } else if command.equals(WindowCommand.ratio) {
        var type: [CChar] = []
        var ratio: [Float] = [0]
        let value = message.next()
        if value.scan(WindowCommand.ratioFormat, &type, &ratio) == 2 {
            let result = wm.adjustWindowRatio(for: actingWindow, type: valueType(type), ratio: ratio[0])
            if result == .invalidSourceView {
                rsp.fail("cannot adjust ratio of a non-managed window.\n")
            } else if result == .invalidSourceNode {
                rsp.fail("cannot adjust ratio of a root node.\n")
            }
        } else {
            rsp.failUnknownValue(domain, command, value)
        }
    } else {
        return .unknown
    }

    return .done
}

//
// NOTE: Window properties: toggles, layer, opacity, order and scratchpads.
//

private func windowCommandProperty(_ rsp: inout Response, _ domain: Token, _ command: Token, _ message: inout some TokenSource, _ actingWindow: Window?) -> CommandResult
{
    let wm = window_manager_global()

    if command.equals(WindowCommand.toggle) {
        //
        // NOTE: A value that is not a window property is a scratchpad label.
        //

        let value = message.next()
        if let toggle = WindowToggle(value) {
            if let window = actingWindow {
                windowToggle(toggle, window)
            } else {
                rsp.fail("could not locate the window to act on!\n")
            }
        } else if !window_manager_toggle_scratchpad_window_by_label(wm, value.string) {
            rsp.failUnknownValue(domain, command, value)
        }
        return .done
    }

    guard let actingWindow else { return .unknown }
    let id = Int32(bitPattern: actingWindow.id.rawValue)

    if command.equals(WindowCommand.subLayer) {
        let value = message.next()
        if let layer = parseLayer(value) {
            if !wm.setWindowLayer(actingWindow, to: layer) {
                rsp.fail("could not change sub-layer of window with id '\(id)' due to an error with the scripting-addition.\n")
            }
        } else {
            rsp.failUnknownValue(domain, command, value)
        }
    } else if command.equals(WindowCommand.opacity) {
        let token = message.next()
        if let opacity = token.value.floatValue, opacity >= 0.0 && opacity <= 1.0 {
            if wm.setOpacity(for: actingWindow, to: opacity) {
                actingWindow.opacity = opacity
            } else {
                rsp.fail("could not change opacity of window with id '\(id)' due to an error with the scripting-addition.\n")
            }
        } else {
            rsp.failUnknownValue(domain, command, token)
        }
    } else if command.equals(WindowCommand.raise) || command.equals(WindowCommand.lower) {
        let raise = command.equals(WindowCommand.raise)
        let selector = parseWindowSelector(&rsp, message.next(), acting: actingWindow, optional: true, CSelectorContext())
        var relativeWid: WindowID?

        if selector.token.isValid {
            guard selector.didParse, let window = selector.value else { return .stop }
            relativeWid = window.id
        }

        if !scripting_addition_order_window(actingWindow.id, raise ? 1 : -1, relativeWid) {
            rsp.fail("could not \(raise ? "raise" : "lower") window with id '\(id)' due to an error with the scripting-addition.\n")
        }
    } else if command.equals(WindowCommand.scratchpad) {
        let token = message.next()
        if token.isValid && token.equals(Argument.recover) {
            window_manager_scratchpad_recover_windows()
        } else {
            let parsed = parseLabel(&rsp, token, .window)
            if parsed.valid {
                if let label = parsed.label {
                    if !window_manager_set_scratchpad_for_window(wm, actingWindow, label.string) {
                        rsp.fail("the given scratchpad is already assigned to a different window!\n")
                    }
                } else if !window_manager_remove_scratchpad_for_window(wm, actingWindow, true) {
                    rsp.fail("the selected window was not assigned to a scratchpad!\n")
                }
            }
        }
    } else {
        return .unknown
    }

    return .done
}

func handleDomainWindow(_ rsp: inout Response, _ domain: Token, _ message: inout some TokenSource)
{
    var command: Token
    var actingWindow: Window? = window_manager_acting_window(window_manager_global())
    var ignored = Response()
    let selector = parseWindowSelector(&ignored, message.next(), acting: actingWindow, optional: true, CSelectorContext())

    if selector.didParse {
        actingWindow = selector.value
        command = message.next()
    } else {
        command = selector.token
    }

    while command.isValid {
        if actingWindow == nil &&
           !command.equals(WindowCommand.focus) &&
           !command.equals(WindowCommand.close) &&
           !command.equals(WindowCommand.minimize) &&
           !command.equals(WindowCommand.deminimize) &&
           !command.equals(WindowCommand.toggle) {
            rsp.fail("could not locate the window to act on!\n")
            return
        }

        var result = windowCommandLifecycle(&rsp, command, &message, &actingWindow)
        if result == .unknown, let window = actingWindow { result = windowCommandPlacement(&rsp, command, &message, window) }
        if result == .unknown { result = windowCommandTree(&rsp, domain, command, &message, actingWindow) }
        if result == .unknown, let window = actingWindow { result = windowCommandFrame(&rsp, domain, command, &message, window) }
        if result == .unknown { result = windowCommandProperty(&rsp, domain, command, &message, actingWindow) }

        if result == .stop { return }
        if result == .unknown { rsp.failUnknownCommand(domain, command) }

        command = message.next()
    }
}
