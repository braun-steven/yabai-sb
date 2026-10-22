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
        case .all:              try rsp.write(json: DisplayID.all.map { $0.info(properties) })
        case .display(let did): try rsp.write(json: did.info(properties))
        case .space(let sid):
            guard let did = sid.display else { throw CommandError("could not find display details.\n") }
            try rsp.write(json: did.info(properties))
        case .window(let window):
            guard let window, let did = window.id.displayID else { throw CommandError("could not find window to retrieve display details.\n") }
            try rsp.write(json: did.info(properties))
        }
    case .spaces(let properties, let target):
        guard let target = try resolve(target, context) else { return }
        let sm = SpaceManager.shared
        switch target {
        case .all:
            let spaceList = SpaceID.all
            if spaceList.isEmpty { throw CommandError("could not retrieve spaces for displays.\n") }
            try rsp.write(json: sm.spaceInfos(spaceList, properties))
        case .display(let did):
            guard let spaceList = did.spaces else { throw CommandError("could not retrieve spaces for display.\n") }
            try rsp.write(json: sm.spaceInfos(spaceList, properties))
        case .space(let sid):
            guard let view = sm.queryView(for: sid) else { throw CommandError("could not retrieve space details.\n") }
            try rsp.write(json: view.info(properties))
        case .window(let window):
            guard let window else { throw CommandError("could not find window to retrieve space details.\n") }
            // NOTE: A window on no space prints nothing.
            let spaceList = window.id.spaces
            if !spaceList.isEmpty { try rsp.write(json: sm.spaceInfos(spaceList, properties)) }
        }
    case .windows(let properties, let target):
        guard let target = try resolve(target, context) else { return }
        let wm = WindowManager.shared
        switch target {
        case .all:              try rsp.write(json: wm.windowInfos(on: SpaceID.all, properties))
        case .display(let did): try rsp.write(json: wm.windowInfos(on: did.spaces ?? [], properties))
        case .space(let sid):   try rsp.write(json: wm.windowInfos(on: [sid], properties))
        case .window(let window):
            guard let window else { throw CommandError("could not retrieve window details.\n") }
            try rsp.write(json: window.info(properties))
        }
    case .tree(let selector):
        let sid: SpaceID?
        if let selector {
            sid = try selector.resolve(acting: context.activeSpace, context)
            if sid == nil, case .recent = selector { return }
        } else {
            sid = context.activeSpace
        }
        guard let sid, let tree = SpaceManager.shared.view(for: sid).treeNode() else {
            throw CommandError("the selected space does not use the tree layout.\n")
        }
        try rsp.write(json: tree)
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
    let command = try RuleCommand.parse(&message, CSelectorContext())
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
            if !WindowManager.shared.reapplyRule(label: label.string) {
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
            if !WindowManager.shared.removeRule(label: label.string) { throw CommandError("rule with label '\(label)' not found.\n") }
        }
    case .list:
        try WindowManager.shared.queryWindowRules(into: &rsp)
    case .ignore:
        break
    }
}

@WM func handleDomainSignal(_ rsp: inout Response, _ domain: Token, _ message: inout some TokenSource) throws(CommandError)
{
    let command = try SignalCommand.parse(&message)
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
        try rsp.write(json: EventSignals.shared.table.list())
    }
}
