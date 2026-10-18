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

    static let layoutTabbed      = "tabbed"
    static let layoutSplit       = "split"
    static let layoutToggle      = "toggle"
    static let layoutSplitH      = "splith"
    static let layoutSplitV      = "splitv"
    static let layoutToggleSplit = "toggle-split"
    static let splitHorizontal   = "horizontal"
    static let splitVertical     = "vertical"
    static let splitToggle       = "toggle"
}

extension Response
{
    mutating func failUnmanagedWindow(_ result: window_op_error)
    {
        if result == WINDOW_OP_ERROR_INVALID_SRC_VIEW || result == WINDOW_OP_ERROR_INVALID_SRC_NODE {
            fail("the acting window is not managed.\n")
        } else if result == WINDOW_OP_ERROR_INVALID_DST_VIEW || result == WINDOW_OP_ERROR_INVALID_DST_NODE {
            fail("the selected window is not managed.\n")
        }
    }
}

private func windowTreeFocus(_ window: Window?, _ focus: TreeFocus) -> window_op_error
{
    let wm = window_manager_global()
    switch focus {
    case .parent:                   return window_manager_tree_focus_parent(wm, window)
    case .child:                    return window_manager_tree_focus_child(wm, window)
    case .direction(let direction): return window_manager_tree_focus_direction(wm, window, direction)
    }
}

/// `parse_window_layout`
func parseWindowLayout(_ value: Token) -> window_layout?
{
    if value.equals(WindowCommand.layoutTabbed)      { return WINDOW_LAYOUT_TABBED }
    if value.equals(WindowCommand.layoutSplit)       { return WINDOW_LAYOUT_SPLIT }
    if value.equals(WindowCommand.layoutToggle)      { return WINDOW_LAYOUT_TOGGLE }
    if value.equals(WindowCommand.layoutSplitH)      { return WINDOW_LAYOUT_SPLITH }
    if value.equals(WindowCommand.layoutSplitV)      { return WINDOW_LAYOUT_SPLITV }
    if value.equals(WindowCommand.layoutToggleSplit) { return WINDOW_LAYOUT_TOGGLE_SPLIT }
    return nil
}

//
// NOTE: -1 toggles the orientation of the parent container.
//

/// `parse_split_orientation`
func parseSplitOrientation(_ value: Token) -> Int32?
{
    if value.equals(WindowCommand.splitHorizontal) { return Int32(CON_HORIZONTAL.rawValue) }
    if value.equals(WindowCommand.splitVertical)   { return Int32(CON_VERTICAL.rawValue) }
    if value.equals(WindowCommand.splitToggle)     { return -1 }
    return nil
}

/// `window_toggle_list`: what a value of `window --toggle` that is a window property does.
private func windowToggle(_ toggle: WindowToggle, _ window: Window)
{
    let sm = space_manager_global()
    let wm = window_manager_global()

    switch toggle {
    case .float:              window_manager_make_window_floating(sm, wm, window, !window_check_flag(window, WINDOW_FLOAT), false)
    case .sticky:             window_manager_make_window_sticky(sm, wm, window, !window_check_flag(window, WINDOW_STICKY))
    case .shadow:             window_manager_toggle_window_shadow(window)
    case .split:              space_manager_toggle_window_split(sm, window)
    case .zoomParent:         window_manager_toggle_window_zoom_parent(wm, window)
    case .zoomFullscreen:     window_manager_toggle_window_zoom_fullscreen(wm, window)
    case .windowedFullscreen: window_manager_toggle_window_windowed_fullscreen(window)
    case .nativeFullscreen:   window_manager_toggle_window_native_fullscreen(window)
    case .expose:             window_manager_toggle_window_expose(window)
    case .pip:                window_manager_toggle_window_pip(sm, window)
    }
}

//
// NOTE: Focusing, closing, minimizing and deminimizing windows.
//

private func windowCommandLifecycle(_ rsp: inout Response, _ command: Token, _ message: inout some TokenSource, _ actingWindow: inout Window?) -> CommandResult
{
    let context = CSelectorContext()

    if command.equals(WindowCommand.focus) {
        let treeFocus = window_manager_find_tree_view(window_manager_global(), actingWindow) != nil ? parseTreeFocus(message.peek()) : nil
        if let treeFocus {
            _ = message.next()

            if windowTreeFocus(actingWindow, treeFocus) != WINDOW_OP_ERROR_SUCCESS {
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
            if !window_manager_close_window(window) {
                rsp.fail("could not close window with id '\(Int32(bitPattern: window.id))'.\n")
            }
        } else {
            rsp.fail("could not locate the window to act on!\n")
        }
    } else if command.equals(WindowCommand.minimize) {
        if !parseOptionalWindowSelector(&rsp, &message, &actingWindow, context) { return .stop }

        if let window = actingWindow {
            let id = Int32(bitPattern: window.id)
            let result = window_manager_minimize_window(window)
            if result == WINDOW_OP_ERROR_CANT_MINIMIZE {
                rsp.fail("window with id '\(id)' does not support the minimize operation.\n")
            } else if result == WINDOW_OP_ERROR_ALREADY_MINIMIZED {
                rsp.fail("window with id '\(id)' is already minimized.\n")
            } else if result == WINDOW_OP_ERROR_MINIMIZE_FAILED {
                rsp.fail("could not minimize window with id '\(id)'.\n")
            }
        } else {
            rsp.fail("could not locate the window to act on!\n")
        }
    } else if command.equals(WindowCommand.deminimize) {
        let selector = parseWindowSelector(&rsp, message.next(), acting: actingWindow, optional: false, context)
        if selector.didParse, let window = selector.value {
            let id = Int32(bitPattern: window.id)
            let result = window_manager_deminimize_window(window)
            if result == WINDOW_OP_ERROR_NOT_MINIMIZED {
                rsp.fail("window with id '\(id)' is not minimized.\n")
            } else if result == WINDOW_OP_ERROR_DEMINIMIZE_FAILED {
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
    let sm = space_manager_global()
    let wm = window_manager_global()
    let context = CSelectorContext()

    if command.equals(WindowCommand.display) {
        let selector = parseDisplaySelector(&rsp, message.next(), acting: display_manager_active_display_id(), optional: false, context)
        if selector.didParse && selector.value != 0 {
            let sid = display_space_id(selector.value)
            if space_is_fullscreen(sid) {
                rsp.fail("can not move window to a macOS fullscreen space!\n")
            } else {
                window_manager_send_window_to_space(sm, wm, actingWindow, sid, false)
            }
        }
    } else if command.equals(WindowCommand.space) {
        let selector = parseSpaceSelector(&rsp, message.next(), acting: space_manager_active_space(), optional: false, context)
        if selector.didParse && selector.value != 0 {
            if space_is_fullscreen(selector.value) {
                rsp.fail("can not move window to a macOS fullscreen space!\n")
            } else {
                window_manager_send_window_to_space(sm, wm, actingWindow, selector.value, false)
            }
        }
    } else if command.equals(WindowCommand.swap) {
        let selector = parseWindowSelector(&rsp, message.next(), acting: actingWindow, optional: false, context)
        if selector.didParse, let window = selector.value {
            let result = window_manager_swap_window(wm, actingWindow, window)
            if result == WINDOW_OP_ERROR_SAME_WINDOW {
                rsp.fail("cannot swap a window with itself.\n")
            } else {
                rsp.failUnmanagedWindow(result)
            }
        }
    } else if command.equals(WindowCommand.warp) {
        if window_manager_find_tree_view(wm, actingWindow) != nil, case .direction(let direction) = parseTreeFocus(message.peek()) {
            _ = message.next()

            if window_manager_tree_move_direction(sm, wm, actingWindow, direction) != WINDOW_OP_ERROR_SUCCESS {
                rsp.fail("could not move the container in that direction.\n")
                return .stop
            }

            return .done
        }

        let selector = parseWindowSelector(&rsp, message.next(), acting: actingWindow, optional: false, context)
        if selector.didParse, let window = selector.value {
            let result = window_manager_warp_window(sm, wm, actingWindow, window)
            if result == WINDOW_OP_ERROR_SAME_WINDOW {
                rsp.fail("cannot warp a window onto itself.\n")
            } else {
                rsp.failUnmanagedWindow(result)
            }
        }
    } else if command.equals(WindowCommand.stack) {
        let selector = parseWindowSelector(&rsp, message.next(), acting: actingWindow, optional: false, context)
        if selector.didParse, let window = selector.value {
            let result = window_manager_stack_window(sm, wm, actingWindow, window)
            if result == WINDOW_OP_ERROR_SAME_WINDOW {
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

        rsp.failUnmanagedWindow(window_manager_set_window_layout(wm, actingWindow, layout))
    } else if command.equals(WindowCommand.split) {
        let value = message.next()
        guard let orientation = parseSplitOrientation(value) else {
            rsp.failUnknownValue(domain, command, value)
            return .stop
        }

        rsp.failUnmanagedWindow(window_manager_tree_split(wm, actingWindow, orientation))
    } else if command.equals(WindowCommand.insert) {
        let selector = parseInsertSelector(&rsp, message.next())
        if selector.didParse, let direction = selector.value {
            rsp.failUnmanagedWindow(window_manager_set_window_insertion(space_manager_global(), actingWindow, direction))
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
    let sm = space_manager_global()
    let wm = window_manager_global()

    if command.equals(WindowCommand.grid) {
        var grid = Grid()
        let value = message.next()
        if grid.scan(value) == 6 {
            let result = window_manager_apply_grid(sm, wm, actingWindow, grid)
            if result == WINDOW_OP_ERROR_INVALID_SRC_VIEW {
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
            let result = window_manager_move_window_relative(wm, actingWindow, Int32(valueType(type)), point[0], point[1])
            if result == WINDOW_OP_ERROR_INVALID_SRC_VIEW {
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
            let result = window_manager_resize_window_relative(wm, actingWindow, Int32(parseResizeHandle(Token(cString: handle)).rawValue), size[0], size[1], true)
            if result == WINDOW_OP_ERROR_INVALID_SRC_NODE {
                rsp.fail("cannot locate the container of the managed window.\n")
            } else if result == WINDOW_OP_ERROR_INVALID_DST_NODE {
                rsp.fail("cannot resize the container in that direction.\n")
            } else if result == WINDOW_OP_ERROR_INVALID_OPERATION {
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
            let result = window_manager_adjust_window_ratio(wm, actingWindow, Int32(valueType(type)), ratio[0])
            if result == WINDOW_OP_ERROR_INVALID_SRC_VIEW {
                rsp.fail("cannot adjust ratio of a non-managed window.\n")
            } else if result == WINDOW_OP_ERROR_INVALID_SRC_NODE {
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
    let id = Int32(bitPattern: actingWindow.id)

    if command.equals(WindowCommand.subLayer) {
        let value = message.next()
        if let layer = parseLayer(value) {
            if !window_manager_set_window_layer(actingWindow, layerValue(layer)) {
                rsp.fail("could not change sub-layer of window with id '\(id)' due to an error with the scripting-addition.\n")
            }
        } else {
            rsp.failUnknownValue(domain, command, value)
        }
    } else if command.equals(WindowCommand.opacity) {
        let token = message.next()
        if let opacity = token.value.floatValue, opacity >= 0.0 && opacity <= 1.0 {
            if window_manager_set_opacity(wm, actingWindow, opacity) {
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
        var relativeWid: UInt32 = 0

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
