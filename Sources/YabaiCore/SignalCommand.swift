/// A selector accepted by `signal --remove`.
public enum SignalSelector {
  case index(Int)
  case label(Token)
}

/// A command of the signal domain, parsed into its operation and payload.
public enum SignalCommand {
  case add(EventSignal, SignalType)
  case remove(SignalSelector)
  case list

  private enum Name: String, CaseIterable {
    case add = "--add"
    case remove = "--remove"
    case list = "--list"
  }

  /// Parses one signal command.
  public static func parse(_ message: inout some TokenSource) throws(CommandError) -> SignalCommand
  {
    let command = message.next()
    guard let name = Name(token: command) else {
      throw CommandError.unknownCommand(Token(Domain.signal), command)
    }

    switch name {
    case .add:
      var signal = EventSignal()
      var event: SignalType?
      try parseSignal(&message, &signal, &event) { SignalType(name: $0) }
      guard let event else { throw CommandError("missing required key-value pair 'event=..'\n") }
      try checkFilters(signal, event)
      return .add(signal, event)

    case .remove:
      let selector = message.next()
      switch selector.value {
      case .int(let index): return .remove(.index(Int(index)))
      case .string: return .remove(.label(selector))
      default: throw CommandError("value '\(selector)' is not a valid option for SIGNAL_SEL\n")
      }

    case .list:
      return .list
    }
  }

  /// Throws for a filter that the event never reports: such a signal would run whatever its filter says.
  private static func checkFilters(_ signal: EventSignal, _ event: SignalType)
    throws(CommandError)
  {
    let given: [(SignalFilters, String, Bool)] = [
      (.app, "app", signal.app != nil),
      (.title, "title", signal.title != nil),
      (.active, "active", signal.active != nil),
    ]
    for (filter, key, isSet) in given where isSet && !event.filters.contains(filter) {
      throw CommandError("event '\(event.name)' does not support the '\(key)' filter\n")
    }
  }
}
