import YabaiCore

extension DisplayCommand {
  /// Runs the command on the acting display.
  @WM fileprivate func run(acting did: DisplayID) throws(CommandError) {
    let context = DaemonSelectorContext()
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
  _ rsp: inout Response, _ domain: Token, _ message: inout Message
) throws(CommandError) {
  let context = DaemonSelectorContext()

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
