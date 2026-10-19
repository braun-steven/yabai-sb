import Darwin
import CPrivate
import YabaiCore

//
// NOTE: The handlers of the query, rule and signal domains.
//

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
    let command = try YabaiCore.RuleCommand.parse(&message, CSelectorContext())
    switch command {
    case .add(let rule):
        WindowManager.shared.addRule(rule)
    case .apply(let target):
        switch target {
        case .all:
            WindowManager.shared.reapplyAllRules()
        case .index(let index):
            if !WindowManager.shared.reapplyRule(at: index) { throw CommandError("rule with index '\(index)' not found.\n") }
        case .labelOrInline(let label, let inline):
            if !WindowManager.shared.reapplyRule(label: label.bytes) {
                switch inline {
                case .success(let rule):
                    if let rule { WindowManager.shared.applyRule(rule) }
                case .failure(let error): throw error
                }
            }
        }
    case .remove(let selector):
        switch selector {
        case .index(let index):
            if !WindowManager.shared.removeRule(at: index) { throw CommandError("rule with index '\(index)' not found.\n") }
        case .label(let label):
            if !WindowManager.shared.removeRule(label: label.bytes) { throw CommandError("rule with label '\(label)' not found.\n") }
        }
    case .list:
        WindowManager.shared.queryWindowRules(into: &rsp)
    case .ignore:
        break
    }
}

@WM func handleDomainSignal(_ rsp: inout Response, _ domain: Token, _ message: inout some TokenSource) throws(CommandError)
{
    let command = try YabaiCore.SignalCommand<SignalType>.parse(&message) { SignalType(name: $0) }
    switch command {
    case .add(let signal, let type): EventSignals.shared.table.add(signal, type)
    case .remove(let selector):
        switch selector {
        case .index(let index):
            if !EventSignals.shared.table.remove(at: index) { throw CommandError("signal with index '\(index)' not found.\n") }
        case .label(let label):
            if !EventSignals.shared.table.remove(label: label.string) { throw CommandError("signal with label '\(label)' not found.\n") }
        }
    case .list:
        rsp.write("\(EventSignals.shared.table.list())")
    }
}
