import Darwin
import CPrivate
import YabaiCore

//
// NOTE: The handlers of the query, rule and signal domains. The rules and signals are C structs until rule.c and
// event_signal.c are Swift (P11, P7), so `rule --list` and `signal --list` are still written by C. Ported from
// src/message.c.
//

/// The commands of the query, rule and signal domains (`COMMAND_QUERY_*`, `COMMAND_RULE_*`, `COMMAND_SIGNAL_*`,
/// `ARGUMENT_QUERY_SPACE` and `ARGUMENT_RULE_ONE_SHOT`, src/message_parse.c).
private enum QueryCommand
{
    static let displays = "--displays"
    static let spaces   = "--spaces"
    static let windows  = "--windows"
    static let tree     = "--tree"

    static let space    = "--space"
}

private enum RuleCommand
{
    static let add     = "--add"
    static let remove  = "--remove"
    static let apply   = "--apply"
    static let list    = "--list"

    static let oneShot = "--one-shot"
}

private enum SignalCommand
{
    static let add    = "--add"
    static let remove = "--remove"
    static let list   = "--list"
}

func handleDomainQuery(_ rsp: inout Response, _ domain: Token, _ message: inout some TokenSource)
{
    let context = CSelectorContext()
    let command = message.next()

    if command.equals(QueryCommand.displays) {
        let properties = parseProperties(&rsp, message.next(), names: DisplayProperty.list.map(\.name), values: DisplayProperty.list.map(\.value))
        if properties.didError { return }

        guard let target = parseQueryTarget(&rsp, domain, command, &message, properties, context) else { return }

        switch target {
        case .all:              displayManagerQueryDisplays(&rsp, properties.flags)
        case .display(let did): rsp.write("\(displaySerialize(did, properties.flags))\n")
        case .space(let sid):
            if let did = sid.display {
                rsp.write("\(displaySerialize(did, properties.flags))\n")
            } else {
                rsp.fail("could not find display details.\n")
            }
        case .window(let window):
            if let window, let did = window.id.displayID {
                rsp.write("\(displaySerialize(did, properties.flags))\n")
            } else {
                rsp.fail("could not find window to retrieve display details.\n")
            }
        }
    } else if command.equals(QueryCommand.spaces) {
        let properties = parseProperties(&rsp, message.next(), names: SpaceProperty.list.map(\.name), values: SpaceProperty.list.map(\.value))
        if properties.didError { return }

        guard let target = parseQueryTarget(&rsp, domain, command, &message, properties, context) else { return }

        switch target {
        case .all:
            if !spaceManagerQuerySpacesForDisplays(&rsp, properties.flags) { rsp.fail("could not retrieve spaces for displays.\n") }
        case .display(let did):
            if !spaceManagerQuerySpacesForDisplay(&rsp, did, properties.flags) { rsp.fail("could not retrieve spaces for display.\n") }
        case .space(let sid):
            if !spaceManagerQuerySpace(&rsp, sid, properties.flags) { rsp.fail("could not retrieve space details.\n") }
        case .window(let window):
            if let window {
                spaceManagerQuerySpacesForWindow(&rsp, window, properties.flags)
            } else {
                rsp.fail("could not find window to retrieve space details.\n")
            }
        }
    } else if command.equals(QueryCommand.windows) {
        let properties = parseProperties(&rsp, message.next(), names: WindowProperty.list.map(\.name), values: WindowProperty.list.map(\.value))
        if properties.didError { return }

        guard let target = parseQueryTarget(&rsp, domain, command, &message, properties, context) else { return }

        switch target {
        case .all:              windowManagerQueryWindowsForDisplays(&rsp, properties.flags)
        case .display(let did): windowManagerQueryWindowsForDisplay(&rsp, did, properties.flags)
        case .space(let sid):   windowManagerQueryWindowsForSpaces(&rsp, [sid], properties.flags)
        case .window(let window):
            if let window {
                rsp.write("\(windowSerialize(window, properties.flags))\n")
            } else {
                rsp.fail("could not retrieve window details.\n")
            }
        }
    } else if command.equals(QueryCommand.tree) {
        var actingSid = SpaceID.active
        let option = message.next()

        if option.equals(QueryCommand.space) {
            if !parseOptionalSpaceSelector(&rsp, &message, &actingSid, context) { return }
        } else if option.isValid {
            rsp.failUnknownOption(domain, command, option)
            return
        }

        guard let sid = actingSid else {
            rsp.fail("the selected space does not use the tree layout.\n")
            return
        }

        let view = space_manager_find_view(space_manager_global(), sid)
        if !treeSerialize(&rsp, view) {
            rsp.fail("the selected space does not use the tree layout.\n")
        }
    } else {
        rsp.failUnknownCommand(domain, command)
    }
}

func handleDomainRule(_ rsp: inout Response, _ domain: Token, _ message: inout some TokenSource)
{
    let command = message.next()

    if command.equals(RuleCommand.add) {
        var result = Rule()

        var token = message.next()
        if token.equals(RuleCommand.oneShot) {
            result.oneShot = true
            token = message.next()
        }

        if parseRule(&rsp, &message, &result, token, CSelectorContext()) {
            WindowManager.shared.addRule(result)
        }
    } else if command.equals(RuleCommand.apply) {
        let token = message.next()
        switch token.value {
        case .int(let index):
            if !WindowManager.shared.reapplyRule(at: Int(index)) {
                rsp.fail("rule with index '\(index)' not found.\n")
            }
        case .string:
            if !WindowManager.shared.reapplyRule(label: token.bytes) {
                var result = Rule()
                if parseRule(&rsp, &message, &result, token, CSelectorContext()) {
                    WindowManager.shared.applyRule(result)
                }
            }
        case .invalid:
            WindowManager.shared.reapplyAllRules()
        default:
            rsp.fail("value '\(token)' is not a valid option for RULE_SEL\n")
        }
    } else if command.equals(RuleCommand.remove) {
        let token = message.next()
        switch token.value {
        case .int(let index):
            if !WindowManager.shared.removeRule(at: Int(index)) {
                rsp.fail("rule with index '\(index)' not found.\n")
            }
        case .string:
            if !WindowManager.shared.removeRule(label: token.bytes) {
                rsp.fail("rule with label '\(token)' not found.\n")
            }
        default:
            rsp.fail("value '\(token)' is not a valid option for RULE_SEL\n")
        }
    } else if command.equals(RuleCommand.list) {
        WindowManager.shared.queryWindowRules(into: &rsp)
    } else {
        rsp.failUnknownCommand(domain, command)
    }
}

@WM func handleDomainSignal(_ rsp: inout Response, _ domain: Token, _ message: inout some TokenSource)
{
    let command = message.next()

    if command.equals(SignalCommand.add) {
        var result = EventSignal()
        var signalType: SignalType?

        if parseSignal(&rsp, &message, &result, &signalType, eventType: { SignalType(name: $0) }), let signalType {
            eventSignals.add(result, signalType)
        }
    } else if command.equals(SignalCommand.remove) {
        let token = message.next()
        switch token.value {
        case .int(let index):
            if !eventSignals.remove(at: Int(index)) {
                rsp.fail("signal with index '\(index)' not found.\n")
            }
        case .string:
            if !eventSignals.remove(label: token.string) {
                rsp.fail("signal with label '\(token)' not found.\n")
            }
        default:
            rsp.fail("value '\(token)' is not a valid option for SIGNAL_SEL\n")
        }
    } else if command.equals(SignalCommand.list) {
        rsp.write("\(eventSignals.list())")
    } else {
        rsp.failUnknownCommand(domain, command)
    }
}
