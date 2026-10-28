import YabaiCore

// NOTE: Runs the commands of a message from first on. A command returns false to stop silently. A failing command
// writes its failure and the next command still runs, unless the failure stops the message (CommandError.stopsMessage):
// handleMessage writes that one.
//

@WM func runCommands(
  _ rsp: inout Response, _ message: inout Message, from first: Token,
  _ run: (inout Response, inout Message, Token) throws(CommandError) -> Bool
) throws(CommandError) {
  if !first.isValid && message.isAtEnd { return }
  var command = first
  while true {
    do {
      if try run(&rsp, &message, command) == false { return }
    } catch  where !error.stopsMessage {
      rsp.fail(error)
    }
    guard let next = message.take() else { return }
    command = next
  }
}

/// Runs the commands of a message and writes the failure that ends it.
@WM func handleMessage(_ response: inout Response, _ message: inout Message) {
  //
  // NOTE: Commands and queries are user-driven and must not see a space list cached before a display change settled
  // (the window server moves spaces between displays for a while after the event). Each message starts from a fresh
  // list; within the message the cache still serves the repeated reads, e.g. one SkyLight call for all space indices
  // of `query --spaces`.
  //
  DisplayManager.shared.invalidateSpaceCaches()

  do {
    try handleDomain(&response, &message)
  } catch {
    response.fail(error)
  }
}

//
// NOTE: The throw of an unknown domain is kept out of handleMessage's do block: a do block that throws directly infers
// any Error for its catch, not CommandError.
//

@WM private func handleDomain(_ response: inout Response, _ message: inout Message)
  throws(CommandError)
{
  let domain = message.next()

  switch Domain(rawValue: domain.string) {
  case .config: try handleDomainConfig(&response, domain, &message)
  case .display: try handleDomainDisplay(&response, domain, &message)
  case .space: try handleDomainSpace(&response, domain, &message)
  case .window: try handleDomainWindow(&response, domain, &message)
  case .query: try handleDomainQuery(&response, domain, &message)
  case .rule: try handleDomainRule(&response, domain, &message)
  case .signal: try handleDomainSignal(&response, domain, &message)
  case .subscribe: try handleDomainSubscribe(&response, &message)
  case .batch:
    throw CommandError("batch reads its commands from stdin and takes no arguments.\n")
  case nil: throw CommandError("unknown domain '\(domain)'\n")
  }
}

/// A response remains associated with its top-level command throughout execution and transport.
struct CommandResponse: Sendable {
  let command: Int
  let response: Response
}

/// Decoding validates the whole envelope, but command parsing and selector resolution remain incremental.
/// A command can change the acting window or space used by the next one.
@WM func executeRequest(_ request: IPCRequest) -> [CommandResponse] {
  let commands: [[String]]
  switch request {
  case .command(let arguments): commands = [arguments]
  case .batch(let batch): commands = batch
  }
  return commands.enumerated().map { index, arguments in
    var response = Response()
    if request.isBatch && arguments.first == Domain.batch.rawValue {
      response.fail(CommandError("batch: a batch cannot contain a batch\n"))
    } else if request.isBatch && arguments.first == Domain.subscribe.rawValue {
      response.fail(
        CommandError("batch: subscribe keeps its client connected and cannot run in a batch\n"))
    } else {
      var message = Message(arguments: arguments)
      handleMessage(&response, &message)
    }
    return CommandResponse(command: index + 1, response: response)
  }
}
