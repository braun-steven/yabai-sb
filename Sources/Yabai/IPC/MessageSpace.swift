import SortedCollections
import YabaiCore

//
// NOTE: The handlers of the display and space domains.
//

//
// NOTE: Throws the failures that every space operation can fail with, so callers only handle the failures specific to
// their operation.
//

private func checkSpaceOperation(_ error: SpaceOperationError, _ action: String)
  throws(CommandError)
{
  switch error {
  case .inMissionControl:
    throw CommandError("cannot \(action) because mission-control is active.\n")
  case .scriptingAdditionFailed:
    throw CommandError("cannot \(action) due to an error with the scripting-addition.\n")
  default: break
  }
}

extension DisplayCommand {
  /// Runs the command on the acting display.
  @WM fileprivate func run(acting did: DisplayID) throws(CommandError) {
    let context = CSelectorContext()
    let dm = DisplayManager.shared
    switch self {
    case .focus(let selector):
      if let target = try selector.resolve(acting: did, context) {
        if did != target {
          // NOTE: Like sway's 'focus output', a direction only picks the display; focus enters it with no direction.
          WindowManager.shared.focusDisplay(target, from: nil)
        } else {
          throw CommandError("cannot focus an already focused display.\n")
        }
      }
    case .space(let selector):
      if let target = try selector.resolve(acting: did.currentSpace, context) {
        do {
          try did.focusSpace(target)
        } catch .sameDisplay {
          throw CommandError("acting display does not contain the given space.\n")
        } catch {
          try checkSpaceOperation(error, "focus space")
        }
      }
    case .label(let token):
      if let label = try parseLabel(token, .display) {
        dm.labels.set(id: did, name: label.string)
      } else if !dm.labels.remove(id: did) {
        throw CommandError("the selected display was not associated with a label!\n")
      }
    }
  }
}

@WM func handleDomainDisplay(
  _ rsp: inout Response, _ domain: Token, _ message: inout some TokenSource
) throws(CommandError) {
  let context = CSelectorContext()

  let command: Token
  var actingDid = DisplayID.active
  let selectorToken = message.next()
  if let selector = DisplaySelector(selectorToken) {
    do {
      actingDid = try selector.resolve(acting: actingDid, context)
      command = message.next()
    } catch {
      if case .label = selector {
        command = selectorToken
      } else {
        actingDid = nil
        command = message.next()
      }
    }
  } else {
    command = selectorToken
  }

  guard let did = actingDid else {
    throw CommandError("could not locate the display to act on!\n")
  }

  guard let name = DisplayCommand.Name(token: command) else {
    throw CommandError.unknownCommand(domain, command)
  }
  try DisplayCommand.parse(name, &message).run(acting: did)
}

extension SpaceCommand {
  /// Runs the command on the acting space. Returns false to stop the message silently, when the optional selector of
  /// --create or --destroy found nothing ('recent'). --create and --destroy make the space they act on the acting
  /// space of the commands that follow it.
  @WM fileprivate func run(acting sid: inout SpaceID?, _ rsp: inout Response) throws(CommandError)
    -> Bool
  {
    let context = CSelectorContext()
    let sm = SpaceManager.shared
    switch self {
    case .focus(let selector), .switch(let selector):
      if let target = try selector.resolve(acting: sid, context) {
        do {
          if case .focus = self {
            try sm.focusSpace(target)
          } else {
            try sm.switchSpace(to: target)
          }
        } catch .sameSpace {
          throw CommandError("cannot focus an already focused space.\n")
        } catch {
          try checkSpaceOperation(error, "focus space")
        }
      }
    case .move(let selector):
      if let target = try selector.resolve(acting: sid, context) {
        guard let sid else {
          throw CommandError("could not locate the space to act on.\n", stopsMessage: true)
        }
        do {
          try sm.moveSpace(sid, to: target)
        } catch .sameSpace {
          throw CommandError("cannot move space to itself.\n")
        } catch .sameDisplay {
          throw CommandError(
            "cannot move space across display boundaries. use --display instead.\n")
        } catch {
          try checkSpaceOperation(error, "move space")
        }
      }
    case .swap(let selector):
      if let target = try selector.resolve(acting: sid, context) {
        guard let sid else {
          throw CommandError("could not locate the space to act on.\n", stopsMessage: true)
        }
        do {
          try sm.swapSpace(sid, with: target)
        } catch .sameSpace {
          throw CommandError("cannot swap space with itself.\n")
        } catch {
          try checkSpaceOperation(error, "swap space")
        }
      }
    case .display(let selector):
      if let target = try selector.resolve(acting: DisplayID.active, context) {
        do {
          try sm.moveSpace(sid, toDisplay: target)
        } catch .missingSource {
          throw CommandError("could not locate the space to act on.\n")
        } catch .missingDestination {
          throw CommandError("could not locate the active space of the given display.\n")
        } catch .invalidSource {
          throw CommandError(
            "acting space is the last user-space on the source display and cannot be moved.\n")
        } catch .invalidDestination {
          throw CommandError("acting space is already located on the given display.\n")
        } catch {
          try checkSpaceOperation(error, "send space to display")
        }
      }
    case .create(let selector):
      if let selector {
        let target: DisplayID?
        do {
          target = try selector.resolve(acting: DisplayID.active, context)
        } catch {
          throw error.stoppingMessage
        }
        guard let target else { return false }
        sid = target.currentSpace
      }
      do {
        try sm.addSpace(onDisplayOf: sid)
      } catch .missingSource {
        throw CommandError("could not locate the space to act on.\n")
      } catch {
        try checkSpaceOperation(error, "create space")
      }
    case .destroy(let selector):
      if let selector {
        let target: SpaceID?
        do {
          target = try selector.resolve(acting: sid, context)
        } catch {
          throw error.stoppingMessage
        }
        guard let target else { return false }
        sid = target
      }
      do {
        try sm.destroySpace(sid)
      } catch .missingSource {
        throw CommandError("could not locate the space to act on.\n")
      } catch .invalidSource {
        throw CommandError(
          "acting space is the last user-space on the source display and cannot be destroyed.\n")
      } catch .invalidType {
        throw CommandError("cannot destroy a macOS fullscreen space.\n")
      } catch {
        try checkSpaceOperation(error, "destroy space")
      }
    case .equalize, .balance:
      //
      // NOTE: A tree is always balanced along both axes, so the optional axis is accepted but has no effect.
      //
      guard let sid else {
        throw CommandError("could not locate the space to act on.\n", stopsMessage: true)
      }
      guard sm.balanceSpace(sid) else {
        throw CommandError("cannot \(isEqualize ? "equalize" : "balance") a non-managed space.\n")
      }
    case .mirror(let axis):
      guard let sid else {
        throw CommandError("could not locate the space to act on.\n", stopsMessage: true)
      }
      let split: WindowSplit = axis == .xAxis ? .x : .y
      guard sm.mirrorSpace(sid, axis: split) else {
        throw CommandError("cannot mirror a non-managed space.\n")
      }
    case .rotate(let degrees):
      guard let sid else {
        throw CommandError("could not locate the space to act on.\n", stopsMessage: true)
      }
      guard sm.rotateSpace(sid, by: degrees) else {
        throw CommandError("cannot rotate a non-managed space.\n")
      }
    case .padding(let type, let top, let bottom, let left, let right):
      guard let sid else {
        throw CommandError("could not locate the space to act on.\n", stopsMessage: true)
      }
      guard sm.setPadding(top: top, bottom: bottom, left: left, right: right, type: type, for: sid)
      else {
        throw CommandError("cannot set padding for a non-managed space.\n")
      }
    case .gap(let type, let gap):
      guard let sid else {
        throw CommandError("could not locate the space to act on.\n", stopsMessage: true)
      }
      guard sm.setGap(gap, type: type, for: sid) else {
        throw CommandError("cannot set gap for a non-managed space.\n")
      }
    case .toggle(let toggle):
      guard let sid else {
        throw CommandError("could not locate the space to act on.\n", stopsMessage: true)
      }
      switch toggle {
      case .padding:
        guard sm.togglePadding(for: sid) else {
          throw CommandError("cannot toggle padding for a non-managed space.\n")
        }
      case .gap:
        guard sm.toggleGap(for: sid) else {
          throw CommandError("cannot toggle gap for a non-managed space.\n")
        }
      case .missionControl: sm.toggleMissionControl(on: sid)
      case .showDesktop: sm.toggleShowDesktop(on: sid)
      }
    case .layout(let layout):
      guard let sid else {
        throw CommandError("could not locate the space to act on.\n", stopsMessage: true)
      }
      guard sid.isUser else {
        throw CommandError("cannot set layout for a macOS fullscreen space!\n")
      }
      sm.setLayout(layout == .float ? .float : .tree, for: sid)
    case .label(let token):
      guard let sid else {
        throw CommandError("could not locate the space to act on.\n", stopsMessage: true)
      }
      if let label = try parseLabel(token, .space) {
        sm.labels.set(id: sid, name: label.string)
      } else if !sm.labels.remove(id: sid) {
        throw CommandError("the selected space was not associated with a label!\n")
      }
      // NOTE: A pin follows its label to the space that gets it. A label that no space has any more takes its pin along.
      sm.dropOrphanedPins()
      sm.schedulePinReconcile(after: .zero, resetPasses: true)
    case .pin(let selector):
      guard let sid else {
        throw CommandError("could not locate the space to act on.\n", stopsMessage: true)
      }
      guard let label = sm.labels.name(of: sid) else {
        throw CommandError("cannot pin a space without a label.\n")
      }
      if let selector {
        let target: DisplayID?
        do {
          target = try selector.resolve(acting: DisplayID.active, context)
        } catch {
          throw error.stoppingMessage
        }
        guard let target else { return false }
        guard let uuid = target.uuid else {
          throw CommandError("could not locate the display to pin the space to.\n")
        }
        sm.pins.pin(label: label, toDisplay: uuid)
      } else {
        sm.pins.unpin(label: label)
      }
      sm.schedulePinReconcile(after: .zero, resetPasses: true)
    case .undo:
      guard let sid else {
        throw CommandError("could not locate the space to act on.\n", stopsMessage: true)
      }
      try undoTreeCommand(on: sid)
    case .saveLayout(let name):
      guard let sid else {
        throw CommandError("could not locate the space to act on.\n", stopsMessage: true)
      }
      guard let directory = layoutDirectory() else {
        throw CommandError("could not locate the layout directory: HOME is not set.\n")
      }
      let path = try saveSpaceLayout(name: name, on: sid, directory: directory)
      rsp.write("\(path)\n")
    case .restoreLayout(let name):
      guard let sid else {
        throw CommandError("could not locate the space to act on.\n", stopsMessage: true)
      }
      guard let directory = layoutDirectory() else {
        throw CommandError("could not locate the layout directory: HOME is not set.\n")
      }
      let reply = try restoreSpaceLayout(name: name, on: sid, directory: directory)
      rsp.write("\(reply)")
    }
    return true
  }

  /// Whether the command equalizes, rather than balances, the space.
  fileprivate var isEqualize: Bool {
    if case .equalize = self { true } else { false }
  }
}

@WM func handleDomainSpace(
  _ rsp: inout Response, _ domain: Token, _ message: inout some TokenSource
) throws(CommandError) {
  let command: Token
  var actingSid = SpaceID.active
  let selectorToken = message.next()
  let context = CSelectorContext()
  if let selector = SpaceSelector(selectorToken) {
    do {
      actingSid = try selector.resolve(acting: actingSid, context)
      command = message.next()
    } catch {
      if case .label = selector {
        command = selectorToken
      } else {
        actingSid = nil
        command = message.next()
      }
    }
  } else {
    command = selectorToken
  }

  if actingSid == nil {
    throw CommandError("could not locate the space to act on!\n")
  }

  try runCommands(&rsp, &message, from: command) {
    (response, source, token) throws(CommandError) -> Bool in
    let name = SpaceCommand.Name(token: token)
    if actingSid == nil && name?.needsActingSpace != false {
      throw CommandError("could not locate the space to act on.\n", stopsMessage: true)
    }
    guard let name else { throw CommandError.unknownCommand(domain, token) }

    let command = try SpaceCommand.parse(name, &source)
    let view = command.changesTree ? actingSid.flatMap { SpaceManager.shared.views[$0] } : nil
    var proceed = true
    try recordingTreeUndo(on: view) { () throws(CommandError) in
      proceed = try command.run(acting: &actingSid, &response)
    }
    return proceed
  }
}
