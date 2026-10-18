import Darwin
import AppKit
import CPrivate
import YabaiCore

//
// NOTE: The handlers of the display and space domains. Ported from src/message_space.c.
//

/// The commands of the display domain (`COMMAND_DISPLAY_*`, src/message_parse.c).
private enum DisplayCommand
{
    static let focus = "--focus"
    static let space = "--space"
    static let label = "--label"
}

/// The commands and arguments of the space domain (`COMMAND_SPACE_*` and `ARGUMENT_SPACE_*`, src/message_parse.c).
private enum SpaceCommand
{
    static let focus    = "--focus"
    static let `switch` = "--switch"
    static let create   = "--create"
    static let destroy  = "--destroy"
    static let move     = "--move"
    static let swap     = "--swap"
    static let display  = "--display"
    static let equalize = "--equalize"
    static let balance  = "--balance"
    static let mirror   = "--mirror"
    static let rotate   = "--rotate"
    static let padding  = "--padding"
    static let gap      = "--gap"
    static let toggle   = "--toggle"
    static let layout   = "--layout"
    static let label    = "--label"

    static let rotate90       = "90"
    static let rotate180      = "180"
    static let rotate270      = "270"
    static let paddingFormat  = "%255[^:]:%d:%d:%d:%d"
    static let gapFormat      = "%255[^:]:%d"
    static let togglePadding  = "padding"
    static let toggleGap      = "gap"
    static let toggleMC       = "mission-control"
    static let toggleSD       = "show-desktop"
    static let layoutFloat    = "float"
    static let layoutTree     = "tree"
}

/// `ARGUMENT_COMMON_VAL_AXIS_X` and `_Y`
enum Axis
{
    static let x = "x-axis"
    static let y = "y-axis"
}

extension Token
{
    /// sscanf with a format like "%255[^:]:%d:%d" (`MAXLEN` buffer for the string, then one pointer per value);
    /// returns the number of assigned conversions.
    func scan<T>(_ format: String, _ type: inout [CChar], _ values: inout [T]) -> Int32
    {
        type = [CChar](repeating: 0, count: 512)
        return type.withUnsafeMutableBufferPointer { t in
            values.withUnsafeMutableBufferPointer { v in
                let arguments: [CVarArg] = [t.baseAddress!] + (0..<v.count).map { v.baseAddress! + $0 }
                return withCString { text in withVaList(arguments) { vsscanf(text, format, $0) } }
            }
        }
    }
}

/// The token of a buffer that sscanf filled.
extension Token
{
    init(cString: UnsafePointer<CChar>?)
    {
        guard let cString else {
            self.init(ArraySlice<UInt8>())
            return
        }

        self.init(UnsafeRawBufferPointer(start: cString, count: strlen(cString)))
    }
}

/// `parse_value_type` of the string a "%255[^:]" conversion read.
func valueType(_ type: [CChar]) -> UInt8
{
    parseValueType(Token(cString: type))?.rawValue ?? 0
}

extension Response
{
    //
    // NOTE: reports the errors that every space operation can fail with, so callers only handle
    // the errors specific to their operation.
    //

    /// `daemon_fail_space_op`
    mutating func failSpaceOp(_ result: space_op_error, _ action: String)
    {
        switch result {
        case SPACE_OP_ERROR_IN_MISSION_CONTROL: fail("cannot \(action) because mission-control is active.\n")
        case SPACE_OP_ERROR_SCRIPTING_ADDITION: fail("cannot \(action) due to an error with the scripting-addition.\n")
        default: break
        }
    }
}

func handleDomainDisplay(_ rsp: inout Response, _ domain: Token, _ message: inout some TokenSource)
{
    let dm = display_manager_global()
    let context = CSelectorContext()

    let command: Token
    var actingDid = display_manager_active_display_id()
    var ignored = Response()
    let selector = parseDisplaySelector(&ignored, message.next(), acting: actingDid, optional: true, context)

    if selector.didParse {
        actingDid = selector.value
        command = message.next()
    } else {
        command = selector.token
    }

    if actingDid == 0 {
        rsp.fail("could not locate the display to act on!\n")
        return
    }

    if command.equals(DisplayCommand.focus) {
        let selector = parseDisplaySelector(&rsp, message.next(), acting: actingDid, optional: false, context)
        if selector.didParse && selector.value != 0 {
            if actingDid != selector.value {
                display_manager_focus_display(selector.value, display_space_id(selector.value))
            } else {
                rsp.fail("cannot focus an already focused display.\n")
            }
        }
    } else if command.equals(DisplayCommand.space) {
        let selector = parseSpaceSelector(&rsp, message.next(), acting: display_space_id(actingDid), optional: false, context)
        if selector.didParse && selector.value != 0 {
            let result = display_manager_focus_space(actingDid, selector.value)
            if result == SPACE_OP_ERROR_SAME_DISPLAY {
                rsp.fail("acting display does not contain the given space.\n")
            } else {
                rsp.failSpaceOp(result, "focus space")
            }
        }
    } else if command.equals(DisplayCommand.label) {
        let parsed = parseLabel(&rsp, message.next(), .display)
        if parsed.valid {
            if let label = parsed.label {
                dm.labels.set(id: UInt64(actingDid), name: label.string)
            } else if !dm.labels.remove(id: UInt64(actingDid)) {
                rsp.fail("the selected display was not associated with a label!\n")
            }
        }
    } else {
        rsp.failUnknownCommand(domain, command)
    }
}

//
// NOTE: A command of a domain is either unknown to a group of commands, done, or failed in a way that
// stops the remaining commands of the message.
//

enum CommandResult
{
    case unknown
    case done
    case stop
}

//
// NOTE: Focusing, moving, swapping, creating and destroying spaces.
//

private func spaceCommandArrange(_ rsp: inout Response, _ command: Token, _ message: inout some TokenSource, _ actingSid: inout UInt64) -> CommandResult
{
    let context = CSelectorContext()

    if command.equals(SpaceCommand.focus) || command.equals(SpaceCommand.switch) {
        let selector = parseSpaceSelector(&rsp, message.next(), acting: actingSid, optional: false, context)
        if selector.didParse && selector.value != 0 {
            let result = command.equals(SpaceCommand.focus)
                       ? space_manager_focus_space(selector.value)
                       : space_manager_switch_space(selector.value)
            if result == SPACE_OP_ERROR_SAME_SPACE {
                rsp.fail("cannot focus an already focused space.\n")
            } else {
                rsp.failSpaceOp(result, "focus space")
            }
        }
    } else if command.equals(SpaceCommand.move) {
        let selector = parseSpaceSelector(&rsp, message.next(), acting: actingSid, optional: false, context)
        if selector.didParse && selector.value != 0 {
            let result = space_manager_move_space_to_space(actingSid, selector.value)
            if result == SPACE_OP_ERROR_SAME_SPACE {
                rsp.fail("cannot move space to itself.\n")
            } else if result == SPACE_OP_ERROR_SAME_DISPLAY {
                rsp.fail("cannot move space across display boundaries. use --display instead.\n")
            } else {
                rsp.failSpaceOp(result, "move space")
            }
        }
    } else if command.equals(SpaceCommand.swap) {
        let selector = parseSpaceSelector(&rsp, message.next(), acting: actingSid, optional: false, context)
        if selector.didParse && selector.value != 0 {
            let result = space_manager_swap_space_with_space(actingSid, selector.value)
            if result == SPACE_OP_ERROR_SAME_SPACE {
                rsp.fail("cannot swap space with itself.\n")
            } else {
                rsp.failSpaceOp(result, "swap space")
            }
        }
    } else if command.equals(SpaceCommand.display) {
        let selector = parseDisplaySelector(&rsp, message.next(), acting: display_manager_active_display_id(), optional: false, context)
        if selector.didParse && selector.value != 0 {
            let result = space_manager_move_space_to_display(space_manager_global(), actingSid, selector.value)
            if result == SPACE_OP_ERROR_MISSING_SRC {
                rsp.fail("could not locate the space to act on.\n")
            } else if result == SPACE_OP_ERROR_MISSING_DST {
                rsp.fail("could not locate the active space of the given display.\n")
            } else if result == SPACE_OP_ERROR_INVALID_SRC {
                rsp.fail("acting space is the last user-space on the source display and cannot be moved.\n")
            } else if result == SPACE_OP_ERROR_INVALID_DST {
                rsp.fail("acting space is already located on the given display.\n")
            } else {
                rsp.failSpaceOp(result, "send space to display")
            }
        }
    } else if command.equals(SpaceCommand.create) {
        let selector = parseDisplaySelector(&rsp, message.next(), acting: display_manager_active_display_id(), optional: true, context)

        if selector.token.isValid {
            if selector.didParse && selector.value != 0 {
                actingSid = display_space_id(selector.value)
            } else {
                return .stop
            }
        }

        let result = space_manager_add_space(actingSid)
        if result == SPACE_OP_ERROR_MISSING_SRC {
            rsp.fail("could not locate the space to act on.\n")
        } else {
            rsp.failSpaceOp(result, "create space")
        }
    } else if command.equals(SpaceCommand.destroy) {
        if !parseOptionalSpaceSelector(&rsp, &message, &actingSid, context) { return .stop }

        let result = space_manager_destroy_space(actingSid)
        if result == SPACE_OP_ERROR_MISSING_SRC {
            rsp.fail("could not locate the space to act on.\n")
        } else if result == SPACE_OP_ERROR_INVALID_SRC {
            rsp.fail("acting space is the last user-space on the source display and cannot be destroyed.\n")
        } else if result == SPACE_OP_ERROR_INVALID_TYPE {
            rsp.fail("cannot destroy a macOS fullscreen space.\n")
        } else {
            rsp.failSpaceOp(result, "destroy space")
        }
    } else {
        return .unknown
    }

    return .done
}

//
// NOTE: The layout, padding, gap and label of a space.
//

func spaceCommandLayout(_ rsp: inout Response, _ domain: Token, _ command: Token, _ message: inout some TokenSource, _ actingSid: UInt64) -> CommandResult
{
    let sm = space_manager_global()

    if command.equals(SpaceCommand.equalize) || command.equals(SpaceCommand.balance) {
        //
        // NOTE: A tree is always balanced along both axes, so the optional axis is accepted but has no effect.
        //

        let value = message.next()
        if value.isValid && !value.equals(Axis.x) && !value.equals(Axis.y) {
            rsp.failUnknownValue(domain, command, value)
        } else if !space_manager_balance_space(sm, actingSid) {
            rsp.fail("cannot \(command.equals(SpaceCommand.equalize) ? "equalize" : "balance") a non-managed space.\n")
        }
    } else if command.equals(SpaceCommand.mirror) {
        let value = message.next()
        let axis = value.equals(Axis.x) ? SPLIT_X
                 : value.equals(Axis.y) ? SPLIT_Y
                 : SPLIT_NONE
        if axis == SPLIT_NONE {
            rsp.failUnknownValue(domain, command, value)
        } else if !space_manager_mirror_space(sm, actingSid, axis) {
            rsp.fail("cannot mirror a non-managed space.\n")
        }
    } else if command.equals(SpaceCommand.rotate) {
        let value = message.next()
        let degrees: Int32 = value.equals(SpaceCommand.rotate90)  ? 90
                           : value.equals(SpaceCommand.rotate180) ? 180
                           : value.equals(SpaceCommand.rotate270) ? 270
                           : 0
        if degrees == 0 {
            rsp.failUnknownValue(domain, command, value)
        } else if !space_manager_rotate_space(sm, actingSid, degrees) {
            rsp.fail("cannot rotate a non-managed space.\n")
        }
    } else if command.equals(SpaceCommand.padding) {
        var type: [CChar] = []
        var spacing: [Int32] = [0, 0, 0, 0]
        let value = message.next()
        if value.scan(SpaceCommand.paddingFormat, &type, &spacing) == 5 {
            if !space_manager_set_padding_for_space(sm, actingSid, Int32(valueType(type)), spacing[0], spacing[1], spacing[2], spacing[3]) {
                rsp.fail("cannot set padding for a non-managed space.\n")
            }
        } else {
            rsp.failUnknownValue(domain, command, value)
        }
    } else if command.equals(SpaceCommand.gap) {
        var type: [CChar] = []
        var gap: [Int32] = [0]
        let value = message.next()
        if value.scan(SpaceCommand.gapFormat, &type, &gap) == 2 {
            if !space_manager_set_gap_for_space(sm, actingSid, Int32(valueType(type)), gap[0]) {
                rsp.fail("cannot set gap for a non-managed space.\n")
            }
        } else {
            rsp.failUnknownValue(domain, command, value)
        }
    } else if command.equals(SpaceCommand.toggle) {
        let value = message.next()
        if value.equals(SpaceCommand.togglePadding) {
            if !space_manager_toggle_padding_for_space(sm, actingSid) {
                rsp.fail("cannot toggle padding for a non-managed space.\n")
            }
        } else if value.equals(SpaceCommand.toggleGap) {
            if !space_manager_toggle_gap_for_space(sm, actingSid) {
                rsp.fail("cannot toggle gap for a non-managed space.\n")
            }
        } else if value.equals(SpaceCommand.toggleMC) {
            space_manager_toggle_mission_control(actingSid)
        } else if value.equals(SpaceCommand.toggleSD) {
            space_manager_toggle_show_desktop(actingSid)
        } else {
            rsp.failUnknownValue(domain, command, value)
        }
    } else if command.equals(SpaceCommand.layout) {
        let value = message.next()
        if value.equals(SpaceCommand.layoutFloat) {
            if space_is_user(actingSid) {
                space_manager_set_layout_for_space(sm, actingSid, VIEW_FLOAT)
            } else {
                rsp.fail("cannot set layout for a macOS fullscreen space!\n")
            }
        } else if value.equals(SpaceCommand.layoutTree) {
            if space_is_user(actingSid) {
                space_manager_set_layout_for_space(sm, actingSid, VIEW_TREE)
            } else {
                rsp.fail("cannot set layout for a macOS fullscreen space!\n")
            }
        } else {
            rsp.failUnknownValue(domain, command, value)
        }
    } else if command.equals(SpaceCommand.label) {
        let parsed = parseLabel(&rsp, message.next(), .space)
        if parsed.valid {
            if let label = parsed.label {
                sm.labels.set(id: actingSid, name: label.string)
            } else if !sm.labels.remove(id: actingSid) {
                rsp.fail("the selected space was not associated with a label!\n")
            }
        }
    } else {
        return .unknown
    }

    return .done
}

func handleDomainSpace(_ rsp: inout Response, _ domain: Token, _ message: inout some TokenSource)
{
    var command: Token
    var actingSid = space_manager_active_space()
    var ignored = Response()
    let selector = parseSpaceSelector(&ignored, message.next(), acting: actingSid, optional: true, CSelectorContext())

    if selector.didParse {
        actingSid = selector.value
        command = message.next()
    } else {
        command = selector.token
    }

    if actingSid == 0 {
        rsp.fail("could not locate the space to act on!\n")
        return
    }

    while command.isValid {
        var result = spaceCommandArrange(&rsp, command, &message, &actingSid)
        if result == .unknown { result = spaceCommandLayout(&rsp, domain, command, &message, actingSid) }

        if result == .stop { return }
        if result == .unknown { rsp.failUnknownCommand(domain, command) }

        command = message.next()
    }
}
