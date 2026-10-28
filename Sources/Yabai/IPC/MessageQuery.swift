import YabaiCore

@WM func handleDomainQuery(
  _ rsp: inout Response, _ domain: Token, _ message: inout Message
) throws(CommandError) {
  try QueryService.execute(QueryCommand.parse(&message), into: &rsp)
}

/// Resolves query targets and collects value snapshots while isolated to the window manager.
@WM enum QueryService {
  static func execute(_ command: QueryCommand, into rsp: inout Response) throws(CommandError) {
    let context = DaemonSelectorContext()
    switch command {
    case .displays(let properties, let target):
      guard let target = try resolve(target, context) else { return }
      switch target {
      case .all: rsp.write(json: .displays(DisplayID.all.map { $0.info(properties) }))
      case .display(let did): rsp.write(json: .display(did.info(properties)))
      case .space(let sid):
        guard let did = sid.display else { throw CommandError("could not find display details.\n") }
        rsp.write(json: .display(did.info(properties)))
      case .window(let window):
        guard let window, let did = window.id.displayID else {
          throw CommandError("could not find window to retrieve display details.\n")
        }
        rsp.write(json: .display(did.info(properties)))
      }
    case .spaces(let properties, let target):
      guard let target = try resolve(target, context) else { return }
      let sm = SpaceManager.shared
      switch target {
      case .all:
        let spaceList = SpaceID.all
        if spaceList.isEmpty { throw CommandError("could not retrieve spaces for displays.\n") }
        rsp.write(json: .spaces(sm.spaceInfos(spaceList, properties)))
      case .display(let did):
        guard let spaceList = did.spaces else {
          throw CommandError("could not retrieve spaces for display.\n")
        }
        rsp.write(json: .spaces(sm.spaceInfos(spaceList, properties)))
      case .space(let sid):
        guard let view = sm.queryView(for: sid) else {
          throw CommandError("could not retrieve space details.\n")
        }
        rsp.write(json: .space(view.info(properties)))
      case .window(let window):
        guard let window else {
          throw CommandError("could not find window to retrieve space details.\n")
        }
        // NOTE: A window on no space prints nothing.
        let spaceList = window.id.spaces
        if !spaceList.isEmpty { rsp.write(json: .spaces(sm.spaceInfos(spaceList, properties))) }
      }
    case .windows(let properties, let target):
      guard let target = try resolve(target, context) else { return }
      let wm = WindowManager.shared
      switch target {
      case .all: rsp.write(json: .windows(wm.windowInfos(on: SpaceID.all, properties)))
      case .display(let did):
        rsp.write(json: .windows(wm.windowInfos(on: did.spaces ?? [], properties)))
      case .space(let sid): rsp.write(json: .windows(wm.windowInfos(on: [sid], properties)))
      case .window(let window):
        guard let window else { throw CommandError("could not retrieve window details.\n") }
        rsp.write(json: .window(window.info(properties)))
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
      rsp.write(json: .tree(tree))
    }
  }
}

private enum ResolvedQueryTarget {
  case all
  case display(DisplayID)
  case space(SpaceID)
  case window(Window?)
}

@WM private func resolve(_ target: QueryCommand.Target, _ context: DaemonSelectorContext)
  throws(CommandError) -> ResolvedQueryTarget?
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
      return .window(try selector.resolve(acting: context.actingWindow(), context))
    }
    return .window(context.actingWindow())
  }
}
