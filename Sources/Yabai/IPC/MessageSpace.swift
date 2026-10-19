import Darwin
import AppKit
import CPrivate
import YabaiCore

//
// NOTE: The handlers of the display and space domains.
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

/// `parse_value_type` of the string a "%255[^:]" conversion read; nil for an unknown type.
func valueType(_ type: [CChar]) -> ValueType?
{
    parseValueType(Token(cString: type))
}

//
// NOTE: Throws the failures that every space operation can fail with, so callers only handle the failures specific to
// their operation.
//

private func checkSpaceOperation(_ error: SpaceOperationError, _ action: String) throws(CommandError)
{
    switch error {
    case .inMissionControl:        throw CommandError("cannot \(action) because mission-control is active.\n")
    case .scriptingAdditionFailed: throw CommandError("cannot \(action) due to an error with the scripting-addition.\n")
    default:                       break
    }
}

@WM func handleDomainDisplay(_ rsp: inout Response, _ domain: Token, _ message: inout some TokenSource) throws(CommandError)
{
    let dm = DisplayManager.shared
    let context = CSelectorContext()

    let command: Token
    var actingDid = DisplayID.active
    let selector = parseDisplaySelector(message.next(), acting: actingDid, optional: true, context)

    if selector.didParse {
        actingDid = selector.value
        command = message.next()
    } else {
        command = selector.token
    }

    guard let did = actingDid else {
        throw CommandError("could not locate the display to act on!\n")
    }

    if command.equals(DisplayCommand.focus) {
        let selector = try parseDisplaySelector(message.next(), acting: did, optional: false, context).checked()
        if selector.didParse, let target = selector.value {
            if did != target {
                target.focus(space: target.currentSpace)
            } else {
                throw CommandError("cannot focus an already focused display.\n")
            }
        }
    } else if command.equals(DisplayCommand.space) {
        let selector = try parseSpaceSelector(message.next(), acting: did.currentSpace, optional: false, context).checked()
        if selector.didParse, let target = selector.value {
            do {
                try did.focusSpace(target)
            } catch .sameDisplay {
                throw CommandError("acting display does not contain the given space.\n")
            } catch {
                try checkSpaceOperation(error, "focus space")
            }
        }
    } else if command.equals(DisplayCommand.label) {
        if let label = try parseLabel(message.next(), .display) {
            dm.labels.set(id: did, name: label.string)
        } else if !dm.labels.remove(id: did) {
            throw CommandError("the selected display was not associated with a label!\n")
        }
    } else {
        throw CommandError.unknownCommand(domain, command)
    }
}

//
// NOTE: Focusing, moving, swapping, creating and destroying spaces.
//

@WM private func spaceCommandArrange(_ command: Token, _ message: inout some TokenSource, _ actingSid: inout SpaceID?) throws(CommandError) -> CommandResult
{
    let context = CSelectorContext()

    if command.equals(SpaceCommand.focus) || command.equals(SpaceCommand.switch) {
        let selector = try parseSpaceSelector(message.next(), acting: actingSid, optional: false, context).checked()
        if selector.didParse, let target = selector.value {
            do {
                if command.equals(SpaceCommand.focus) {
                    try SpaceManager.shared.focusSpace(target)
                } else {
                    try SpaceManager.shared.switchSpace(to: target)
                }
            } catch .sameSpace {
                throw CommandError("cannot focus an already focused space.\n")
            } catch {
                try checkSpaceOperation(error, "focus space")
            }
        }
    } else if command.equals(SpaceCommand.move) {
        let selector = try parseSpaceSelector(message.next(), acting: actingSid, optional: false, context).checked()
        if selector.didParse, let target = selector.value {
            guard let actingSid else {
                throw CommandError("could not locate the space to act on.\n", stopsMessage: true)
            }

            do {
                try SpaceManager.shared.moveSpace(actingSid, to: target)
            } catch .sameSpace {
                throw CommandError("cannot move space to itself.\n")
            } catch .sameDisplay {
                throw CommandError("cannot move space across display boundaries. use --display instead.\n")
            } catch {
                try checkSpaceOperation(error, "move space")
            }
        }
    } else if command.equals(SpaceCommand.swap) {
        let selector = try parseSpaceSelector(message.next(), acting: actingSid, optional: false, context).checked()
        if selector.didParse, let target = selector.value {
            guard let actingSid else {
                throw CommandError("could not locate the space to act on.\n", stopsMessage: true)
            }

            do {
                try SpaceManager.shared.swapSpace(actingSid, with: target)
            } catch .sameSpace {
                throw CommandError("cannot swap space with itself.\n")
            } catch {
                try checkSpaceOperation(error, "swap space")
            }
        }
    } else if command.equals(SpaceCommand.display) {
        let selector = try parseDisplaySelector(message.next(), acting: DisplayID.active, optional: false, context).checked()
        if selector.didParse, let target = selector.value {
            do {
                try SpaceManager.shared.moveSpace(actingSid, toDisplay: target)
            } catch .missingSource {
                throw CommandError("could not locate the space to act on.\n")
            } catch .missingDestination {
                throw CommandError("could not locate the active space of the given display.\n")
            } catch .invalidSource {
                throw CommandError("acting space is the last user-space on the source display and cannot be moved.\n")
            } catch .invalidDestination {
                throw CommandError("acting space is already located on the given display.\n")
            } catch {
                try checkSpaceOperation(error, "send space to display")
            }
        }
    } else if command.equals(SpaceCommand.create) {
        let selector = parseDisplaySelector(message.next(), acting: DisplayID.active, optional: true, context)

        if selector.token.isValid {
            if let failure = selector.failure { throw failure.stoppingMessage }
            guard selector.didParse, let target = selector.value else { return .stop }
            actingSid = target.currentSpace
        }

        do {
            try SpaceManager.shared.addSpace(onDisplayOf: actingSid)
        } catch .missingSource {
            throw CommandError("could not locate the space to act on.\n")
        } catch {
            try checkSpaceOperation(error, "create space")
        }
    } else if command.equals(SpaceCommand.destroy) {
        do {
            if !(try parseOptionalSpaceSelector(&message, &actingSid, context)) { return .stop }
        } catch {
            throw error.stoppingMessage
        }

        do {
            try SpaceManager.shared.destroySpace(actingSid)
        } catch .missingSource {
            throw CommandError("could not locate the space to act on.\n")
        } catch .invalidSource {
            throw CommandError("acting space is the last user-space on the source display and cannot be destroyed.\n")
        } catch .invalidType {
            throw CommandError("cannot destroy a macOS fullscreen space.\n")
        } catch {
            try checkSpaceOperation(error, "destroy space")
        }
    } else {
        return .unknown
    }

    return .done
}

//
// NOTE: The layout, padding, gap and label of a space.
//

@WM func spaceCommandLayout(_ domain: Token, _ command: Token, _ message: inout some TokenSource, _ actingSid: SpaceID) throws(CommandError) -> CommandResult
{
    let sm = SpaceManager.shared

    if command.equals(SpaceCommand.equalize) || command.equals(SpaceCommand.balance) {
        //
        // NOTE: A tree is always balanced along both axes, so the optional axis is accepted but has no effect.
        //

        let value = message.next()
        if value.isValid && !value.equals(Axis.x) && !value.equals(Axis.y) {
            throw CommandError.unknownValue(domain, command, value)
        } else if !sm.balanceSpace(actingSid) {
            throw CommandError("cannot \(command.equals(SpaceCommand.equalize) ? "equalize" : "balance") a non-managed space.\n")
        }
    } else if command.equals(SpaceCommand.mirror) {
        let value = message.next()
        let axis: WindowSplit? = value.equals(Axis.x) ? .x
                               : value.equals(Axis.y) ? .y
                               : nil
        if let axis {
            if !sm.mirrorSpace(actingSid, axis: axis) {
                throw CommandError("cannot mirror a non-managed space.\n")
            }
        } else {
            throw CommandError.unknownValue(domain, command, value)
        }
    } else if command.equals(SpaceCommand.rotate) {
        let value = message.next()
        let degrees = value.equals(SpaceCommand.rotate90)  ? 90
                           : value.equals(SpaceCommand.rotate180) ? 180
                           : value.equals(SpaceCommand.rotate270) ? 270
                           : 0
        if degrees == 0 {
            throw CommandError.unknownValue(domain, command, value)
        } else if !sm.rotateSpace(actingSid, by: degrees) {
            throw CommandError("cannot rotate a non-managed space.\n")
        }
    } else if command.equals(SpaceCommand.padding) {
        var type: [CChar] = []
        var spacing: [Int32] = [0, 0, 0, 0]
        let value = message.next()
        if value.scan(SpaceCommand.paddingFormat, &type, &spacing) == 5 {
            if !sm.setPadding(top: Int(spacing[0]), bottom: Int(spacing[1]), left: Int(spacing[2]), right: Int(spacing[3]), type: valueType(type), for: actingSid) {
                throw CommandError("cannot set padding for a non-managed space.\n")
            }
        } else {
            throw CommandError.unknownValue(domain, command, value)
        }
    } else if command.equals(SpaceCommand.gap) {
        var type: [CChar] = []
        var gap: [Int32] = [0]
        let value = message.next()
        if value.scan(SpaceCommand.gapFormat, &type, &gap) == 2 {
            if !sm.setGap(Int(gap[0]), type: valueType(type), for: actingSid) {
                throw CommandError("cannot set gap for a non-managed space.\n")
            }
        } else {
            throw CommandError.unknownValue(domain, command, value)
        }
    } else if command.equals(SpaceCommand.toggle) {
        let value = message.next()
        if value.equals(SpaceCommand.togglePadding) {
            if !sm.togglePadding(for: actingSid) {
                throw CommandError("cannot toggle padding for a non-managed space.\n")
            }
        } else if value.equals(SpaceCommand.toggleGap) {
            if !sm.toggleGap(for: actingSid) {
                throw CommandError("cannot toggle gap for a non-managed space.\n")
            }
        } else if value.equals(SpaceCommand.toggleMC) {
            SpaceManager.shared.toggleMissionControl(on: actingSid)
        } else if value.equals(SpaceCommand.toggleSD) {
            SpaceManager.shared.toggleShowDesktop(on: actingSid)
        } else {
            throw CommandError.unknownValue(domain, command, value)
        }
    } else if command.equals(SpaceCommand.layout) {
        let value = message.next()
        if value.equals(SpaceCommand.layoutFloat) {
            if actingSid.isUser {
                sm.setLayout(.float, for: actingSid)
            } else {
                throw CommandError("cannot set layout for a macOS fullscreen space!\n")
            }
        } else if value.equals(SpaceCommand.layoutTree) {
            if actingSid.isUser {
                sm.setLayout(.tree, for: actingSid)
            } else {
                throw CommandError("cannot set layout for a macOS fullscreen space!\n")
            }
        } else {
            throw CommandError.unknownValue(domain, command, value)
        }
    } else if command.equals(SpaceCommand.label) {
        if let label = try parseLabel(message.next(), .space) {
            sm.labels.set(id: actingSid, name: label.string)
        } else if !sm.labels.remove(id: actingSid) {
            throw CommandError("the selected space was not associated with a label!\n")
        }
    } else {
        return .unknown
    }

    return .done
}

@WM func handleDomainSpace(_ rsp: inout Response, _ domain: Token, _ message: inout some TokenSource) throws(CommandError)
{
    let command: Token
    var actingSid = SpaceID.active
    let selector = parseSpaceSelector(message.next(), acting: actingSid, optional: true, CSelectorContext())

    if selector.didParse {
        actingSid = selector.value
        command = message.next()
    } else {
        command = selector.token
    }

    if actingSid == nil {
        throw CommandError("could not locate the space to act on!\n")
    }

    try runCommands(&rsp, &message, from: command) { (_, source, command) throws(CommandError) -> CommandResult in
        var result = try spaceCommandArrange(command, &source, &actingSid)
        if result == .unknown {
            guard let sid = actingSid else {
                throw CommandError("could not locate the space to act on.\n", stopsMessage: true)
            }

            result = try spaceCommandLayout(domain, command, &source, sid)
        }

        if result == .unknown { throw CommandError.unknownCommand(domain, command) }
        return result
    }
}
