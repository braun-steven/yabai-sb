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
    func scan<T>(_ format: String, _ type: inout [CChar], _ values: inout [T]) -> Int
    {
        type = [CChar](repeating: 0, count: 512)
        return type.withUnsafeMutableBufferPointer { t in
            values.withUnsafeMutableBufferPointer { v in
                let arguments: [CVarArg] = [t.baseAddress!] + (0..<v.count).map { v.baseAddress! + $0 }
                return Int(withCString { text in withVaList(arguments) { vsscanf(text, format, $0) } })
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

/// `parse_value_type` of the string a "%255[^:]" conversion read; nil for an unknown type.
func valueType(_ type: [CChar]) -> ValueType?
{
    parseValueType(Token(cString: type))
}

extension Response
{
    //
    // NOTE: reports the errors that every space operation can fail with, so callers only handle
    // the errors specific to their operation.
    //

    /// `daemon_fail_space_op`
    mutating func failSpaceOp(_ result: SpaceOperationResult, _ action: String)
    {
        switch result {
        case .inMissionControl: fail("cannot \(action) because mission-control is active.\n")
        case .scriptingAdditionFailed: fail("cannot \(action) due to an error with the scripting-addition.\n")
        default: break
        }
    }
}

@WM func handleDomainDisplay(_ rsp: inout Response, _ domain: Token, _ message: inout some TokenSource)
{
    let dm = DisplayManager.shared
    let context = CSelectorContext()

    let command: Token
    var actingDid = DisplayID.active
    var ignored = Response()
    let selector = parseDisplaySelector(&ignored, message.next(), acting: actingDid, optional: true, context)

    if selector.didParse {
        actingDid = selector.value
        command = message.next()
    } else {
        command = selector.token
    }

    guard let did = actingDid else {
        rsp.fail("could not locate the display to act on!\n")
        return
    }

    if command.equals(DisplayCommand.focus) {
        let selector = parseDisplaySelector(&rsp, message.next(), acting: did, optional: false, context)
        if selector.didParse, let target = selector.value {
            if did != target {
                target.focus(space: target.currentSpace)
            } else {
                rsp.fail("cannot focus an already focused display.\n")
            }
        }
    } else if command.equals(DisplayCommand.space) {
        let selector = parseSpaceSelector(&rsp, message.next(), acting: did.currentSpace, optional: false, context)
        if selector.didParse, let target = selector.value {
            let result = did.focusSpace(target)
            if result == .sameDisplay {
                rsp.fail("acting display does not contain the given space.\n")
            } else {
                rsp.failSpaceOp(result, "focus space")
            }
        }
    } else if command.equals(DisplayCommand.label) {
        let parsed = parseLabel(&rsp, message.next(), .display)
        if parsed.valid {
            if let label = parsed.label {
                dm.labels.set(id: did, name: label.string)
            } else if !dm.labels.remove(id: did) {
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

@WM private func spaceCommandArrange(_ rsp: inout Response, _ command: Token, _ message: inout some TokenSource, _ actingSid: inout SpaceID?) -> CommandResult
{
    let context = CSelectorContext()

    if command.equals(SpaceCommand.focus) || command.equals(SpaceCommand.switch) {
        let selector = parseSpaceSelector(&rsp, message.next(), acting: actingSid, optional: false, context)
        if selector.didParse, let target = selector.value {
            let result = command.equals(SpaceCommand.focus)
                       ? SpaceManager.shared.focusSpace(target)
                       : SpaceManager.shared.switchSpace(to: target)
            if result == .sameSpace {
                rsp.fail("cannot focus an already focused space.\n")
            } else {
                rsp.failSpaceOp(result, "focus space")
            }
        }
    } else if command.equals(SpaceCommand.move) {
        let selector = parseSpaceSelector(&rsp, message.next(), acting: actingSid, optional: false, context)
        if selector.didParse, let target = selector.value {
            guard let actingSid else {
                rsp.fail("could not locate the space to act on.\n")
                return .stop
            }

            let result = SpaceManager.shared.moveSpace(actingSid, to: target)
            if result == .sameSpace {
                rsp.fail("cannot move space to itself.\n")
            } else if result == .sameDisplay {
                rsp.fail("cannot move space across display boundaries. use --display instead.\n")
            } else {
                rsp.failSpaceOp(result, "move space")
            }
        }
    } else if command.equals(SpaceCommand.swap) {
        let selector = parseSpaceSelector(&rsp, message.next(), acting: actingSid, optional: false, context)
        if selector.didParse, let target = selector.value {
            guard let actingSid else {
                rsp.fail("could not locate the space to act on.\n")
                return .stop
            }

            let result = SpaceManager.shared.swapSpace(actingSid, with: target)
            if result == .sameSpace {
                rsp.fail("cannot swap space with itself.\n")
            } else {
                rsp.failSpaceOp(result, "swap space")
            }
        }
    } else if command.equals(SpaceCommand.display) {
        let selector = parseDisplaySelector(&rsp, message.next(), acting: DisplayID.active, optional: false, context)
        if selector.didParse, let target = selector.value {
            let result = SpaceManager.shared.moveSpace(actingSid, toDisplay: target)
            if result == .missingSource {
                rsp.fail("could not locate the space to act on.\n")
            } else if result == .missingDestination {
                rsp.fail("could not locate the active space of the given display.\n")
            } else if result == .invalidSource {
                rsp.fail("acting space is the last user-space on the source display and cannot be moved.\n")
            } else if result == .invalidDestination {
                rsp.fail("acting space is already located on the given display.\n")
            } else {
                rsp.failSpaceOp(result, "send space to display")
            }
        }
    } else if command.equals(SpaceCommand.create) {
        let selector = parseDisplaySelector(&rsp, message.next(), acting: DisplayID.active, optional: true, context)

        if selector.token.isValid {
            if selector.didParse, let target = selector.value {
                actingSid = target.currentSpace
            } else {
                return .stop
            }
        }

        let result = SpaceManager.shared.addSpace(onDisplayOf: actingSid)
        if result == .missingSource {
            rsp.fail("could not locate the space to act on.\n")
        } else {
            rsp.failSpaceOp(result, "create space")
        }
    } else if command.equals(SpaceCommand.destroy) {
        if !parseOptionalSpaceSelector(&rsp, &message, &actingSid, context) { return .stop }

        let result = SpaceManager.shared.destroySpace(actingSid)
        if result == .missingSource {
            rsp.fail("could not locate the space to act on.\n")
        } else if result == .invalidSource {
            rsp.fail("acting space is the last user-space on the source display and cannot be destroyed.\n")
        } else if result == .invalidType {
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

@WM func spaceCommandLayout(_ rsp: inout Response, _ domain: Token, _ command: Token, _ message: inout some TokenSource, _ actingSid: SpaceID) -> CommandResult
{
    let sm = SpaceManager.shared

    if command.equals(SpaceCommand.equalize) || command.equals(SpaceCommand.balance) {
        //
        // NOTE: A tree is always balanced along both axes, so the optional axis is accepted but has no effect.
        //

        let value = message.next()
        if value.isValid && !value.equals(Axis.x) && !value.equals(Axis.y) {
            rsp.failUnknownValue(domain, command, value)
        } else if !sm.balanceSpace(actingSid) {
            rsp.fail("cannot \(command.equals(SpaceCommand.equalize) ? "equalize" : "balance") a non-managed space.\n")
        }
    } else if command.equals(SpaceCommand.mirror) {
        let value = message.next()
        let axis: WindowSplit? = value.equals(Axis.x) ? .x
                               : value.equals(Axis.y) ? .y
                               : nil
        if let axis {
            if !sm.mirrorSpace(actingSid, axis: axis) {
                rsp.fail("cannot mirror a non-managed space.\n")
            }
        } else {
            rsp.failUnknownValue(domain, command, value)
        }
    } else if command.equals(SpaceCommand.rotate) {
        let value = message.next()
        let degrees = value.equals(SpaceCommand.rotate90)  ? 90
                           : value.equals(SpaceCommand.rotate180) ? 180
                           : value.equals(SpaceCommand.rotate270) ? 270
                           : 0
        if degrees == 0 {
            rsp.failUnknownValue(domain, command, value)
        } else if !sm.rotateSpace(actingSid, by: degrees) {
            rsp.fail("cannot rotate a non-managed space.\n")
        }
    } else if command.equals(SpaceCommand.padding) {
        var type: [CChar] = []
        var spacing: [Int32] = [0, 0, 0, 0]
        let value = message.next()
        if value.scan(SpaceCommand.paddingFormat, &type, &spacing) == 5 {
            if !sm.setPadding(top: Int(spacing[0]), bottom: Int(spacing[1]), left: Int(spacing[2]), right: Int(spacing[3]), type: valueType(type), for: actingSid) {
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
            if !sm.setGap(Int(gap[0]), type: valueType(type), for: actingSid) {
                rsp.fail("cannot set gap for a non-managed space.\n")
            }
        } else {
            rsp.failUnknownValue(domain, command, value)
        }
    } else if command.equals(SpaceCommand.toggle) {
        let value = message.next()
        if value.equals(SpaceCommand.togglePadding) {
            if !sm.togglePadding(for: actingSid) {
                rsp.fail("cannot toggle padding for a non-managed space.\n")
            }
        } else if value.equals(SpaceCommand.toggleGap) {
            if !sm.toggleGap(for: actingSid) {
                rsp.fail("cannot toggle gap for a non-managed space.\n")
            }
        } else if value.equals(SpaceCommand.toggleMC) {
            SpaceManager.shared.toggleMissionControl(on: actingSid)
        } else if value.equals(SpaceCommand.toggleSD) {
            SpaceManager.shared.toggleShowDesktop(on: actingSid)
        } else {
            rsp.failUnknownValue(domain, command, value)
        }
    } else if command.equals(SpaceCommand.layout) {
        let value = message.next()
        if value.equals(SpaceCommand.layoutFloat) {
            if actingSid.isUser {
                sm.setLayout(.float, for: actingSid)
            } else {
                rsp.fail("cannot set layout for a macOS fullscreen space!\n")
            }
        } else if value.equals(SpaceCommand.layoutTree) {
            if actingSid.isUser {
                sm.setLayout(.tree, for: actingSid)
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

@WM func handleDomainSpace(_ rsp: inout Response, _ domain: Token, _ message: inout some TokenSource)
{
    var command: Token
    var actingSid = SpaceID.active
    var ignored = Response()
    let selector = parseSpaceSelector(&ignored, message.next(), acting: actingSid, optional: true, CSelectorContext())

    if selector.didParse {
        actingSid = selector.value
        command = message.next()
    } else {
        command = selector.token
    }

    if actingSid == nil {
        rsp.fail("could not locate the space to act on!\n")
        return
    }

    while command.isValid {
        var result = spaceCommandArrange(&rsp, command, &message, &actingSid)
        if result == .unknown {
            guard let sid = actingSid else {
                rsp.fail("could not locate the space to act on.\n")
                return
            }

            result = spaceCommandLayout(&rsp, domain, command, &message, sid)
        }

        if result == .stop { return }
        if result == .unknown { rsp.failUnknownCommand(domain, command) }

        command = message.next()
    }
}
