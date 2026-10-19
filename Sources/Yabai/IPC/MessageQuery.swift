import Darwin
import CPrivate
import YabaiCore

//
// NOTE: The handlers of the query, rule and signal domains.
//

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

@WM func handleDomainQuery(_ rsp: inout Response, _ domain: Token, _ message: inout some TokenSource) throws(CommandError)
{
    let context = CSelectorContext()
    let command = try QueryCommand.parse(&message)

    switch command {
    case .displays(let properties, let target):
        guard let target = try resolve(target, context) else { return }
        switch target {
        case .all:              displayManagerQueryDisplays(&rsp, properties)
        case .display(let did): rsp.write("\(displaySerialize(did, properties))\n")
        case .space(let sid):
            if let did = sid.display { rsp.write("\(displaySerialize(did, properties))\n") }
            else { throw CommandError("could not find display details.\n") }
        case .window(let window):
            if let window, let did = window.id.displayID { rsp.write("\(displaySerialize(did, properties))\n") }
            else { throw CommandError("could not find window to retrieve display details.\n") }
        }
    case .spaces(let properties, let target):
        guard let target = try resolve(target, context) else { return }
        switch target {
        case .all:
            if !spaceManagerQuerySpacesForDisplays(&rsp, properties) { throw CommandError("could not retrieve spaces for displays.\n") }
        case .display(let did):
            if !spaceManagerQuerySpacesForDisplay(&rsp, did, properties) { throw CommandError("could not retrieve spaces for display.\n") }
        case .space(let sid):
            if !spaceManagerQuerySpace(&rsp, sid, properties) { throw CommandError("could not retrieve space details.\n") }
        case .window(let window):
            if let window { spaceManagerQuerySpacesForWindow(&rsp, window, properties) }
            else { throw CommandError("could not find window to retrieve space details.\n") }
        }
    case .windows(let properties, let target):
        guard let target = try resolve(target, context) else { return }
        switch target {
        case .all:              windowManagerQueryWindowsForDisplays(&rsp, properties)
        case .display(let did): windowManagerQueryWindowsForDisplay(&rsp, did, properties)
        case .space(let sid):   windowManagerQueryWindowsForSpaces(&rsp, [sid], properties)
        case .window(let window):
            if let window { rsp.write("\(windowSerialize(window, properties))\n") }
            else { throw CommandError("could not retrieve window details.\n") }
        }
    case .tree(let selector):
        let sid: SpaceID?
        if let selector {
            sid = try selector.resolve(acting: context.activeSpace, context)
            if sid == nil, case .recent = selector { return }
        } else {
            sid = context.activeSpace
        }
        guard let sid else { throw CommandError("the selected space does not use the tree layout.\n") }
        if !treeSerialize(&rsp, SpaceManager.shared.view(for: sid)) {
            throw CommandError("the selected space does not use the tree layout.\n")
        }
    }
}

private enum ResolvedQueryTarget
{
    case all
    case display(DisplayID)
    case space(SpaceID)
    case window(Window?)
}

@WM private func resolve(_ target: QueryCommand.Target, _ context: CSelectorContext) throws(CommandError) -> ResolvedQueryTarget?
{
    switch target {
    case .all:
        return .all
    case .display(let selector):
        let did: DisplayID?
        if let selector {
            did = try selector.resolve(acting: context.activeDisplay, context)
            if did == nil, case .recent = selector { return nil }
        } else {
            did = context.activeDisplay
        }
        guard let did else { throw CommandError("could not locate the selected display.\n") }
        return .display(did)
    case .space(let selector):
        let sid: SpaceID?
        if let selector {
            sid = try selector.resolve(acting: context.activeSpace, context)
            if sid == nil, case .recent = selector { return nil }
        } else {
            sid = context.activeSpace
        }
        guard let sid else { throw CommandError("could not locate the selected space.\n") }
        return .space(sid)
    case .window(let selector):
        if let selector {
            return .window(try selector.resolve(acting: context.actingWindow, context))
        }
        return .window(context.actingWindow)
    }
}

@WM func handleDomainRule(_ rsp: inout Response, _ domain: Token, _ message: inout some TokenSource) throws(CommandError)
{
    let command = message.next()

    if command.equals(RuleCommand.add) {
        var result = Rule()

        var token = message.next()
        if token.equals(RuleCommand.oneShot) {
            result.oneShot = true
            token = message.next()
        }

        if try parseRule(&message, &result, token, CSelectorContext()) {
            WindowManager.shared.addRule(result)
        }
    } else if command.equals(RuleCommand.apply) {
        let token = message.next()
        switch token.value {
        case .int(let index):
            if !WindowManager.shared.reapplyRule(at: Int(index)) {
                throw CommandError("rule with index '\(index)' not found.\n")
            }
        case .string:
            if !WindowManager.shared.reapplyRule(label: token.bytes) {
                var result = Rule()
                if try parseRule(&message, &result, token, CSelectorContext()) {
                    WindowManager.shared.applyRule(result)
                }
            }
        case .invalid:
            WindowManager.shared.reapplyAllRules()
        default:
            throw CommandError("value '\(token)' is not a valid option for RULE_SEL\n")
        }
    } else if command.equals(RuleCommand.remove) {
        let token = message.next()
        switch token.value {
        case .int(let index):
            if !WindowManager.shared.removeRule(at: Int(index)) {
                throw CommandError("rule with index '\(index)' not found.\n")
            }
        case .string:
            if !WindowManager.shared.removeRule(label: token.bytes) {
                throw CommandError("rule with label '\(token)' not found.\n")
            }
        default:
            throw CommandError("value '\(token)' is not a valid option for RULE_SEL\n")
        }
    } else if command.equals(RuleCommand.list) {
        WindowManager.shared.queryWindowRules(into: &rsp)
    } else {
        throw CommandError.unknownCommand(domain, command)
    }
}

@WM func handleDomainSignal(_ rsp: inout Response, _ domain: Token, _ message: inout some TokenSource) throws(CommandError)
{
    let command = message.next()

    if command.equals(SignalCommand.add) {
        var result = EventSignal()
        var signalType: SignalType?

        try parseSignal(&message, &result, &signalType, eventType: { SignalType(name: $0) })
        if let signalType {
            EventSignals.shared.table.add(result, signalType)
        }
    } else if command.equals(SignalCommand.remove) {
        let token = message.next()
        switch token.value {
        case .int(let index):
            if !EventSignals.shared.table.remove(at: Int(index)) {
                throw CommandError("signal with index '\(index)' not found.\n")
            }
        case .string:
            if !EventSignals.shared.table.remove(label: token.string) {
                throw CommandError("signal with label '\(token)' not found.\n")
            }
        default:
            throw CommandError("value '\(token)' is not a valid option for SIGNAL_SEL\n")
        }
    } else if command.equals(SignalCommand.list) {
        rsp.write("\(EventSignals.shared.table.list())")
    } else {
        throw CommandError.unknownCommand(domain, command)
    }
}
