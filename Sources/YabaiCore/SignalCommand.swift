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
  public static func parse(_ message: inout Message) throws(CommandError) -> SignalCommand {
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

/// Parse signal fields to the end of the message, resolving event names with eventType.
/// Report all field problems together when the signal is invalid.
public func parseSignal<Event>(
  _ message: inout Message, _ signal: inout EventSignal, _ event: inout Event?,
  eventType: (Token) -> Event?
) throws(CommandError) {
  var scanner = KeyValueScanner(first: message.take())
  var hasSignalType = false
  event = nil

  while let pair = scanner.next(&message) {
    let key = pair.key
    let value = pair.value
    var isFilter = false
    var validValue = true
    var validPattern = true

    if key.equals("label") {
      signal.label = value.string
    } else if key.equals("app") {
      isFilter = true
      signal.app = RulePattern(value, exclude: pair.exclusion)
      validPattern = signal.app?.regex != nil
    } else if key.equals("title") {
      isFilter = true
      signal.title = RulePattern(value, exclude: pair.exclusion)
      validPattern = signal.title?.regex != nil
    } else if key.equals("active") {
      if value.equals("yes") {
        signal.active = true
      } else if value.equals("no") {
        signal.active = false
      } else {
        validValue = false
      }
    } else if key.equals("action") {
      signal.command = value.string
    } else if key.equals("event") {
      hasSignalType = true
      event = eventType(value)
      validValue = event != nil
    } else {
      scanner.unknownKey(key)
      continue
    }

    scanner.check(pair, filter: isFilter, validValue: validValue, validPattern: validPattern)
  }

  if !hasSignalType { scanner.fail(CommandError("missing required key-value pair 'event=..'\n")) }
  if signal.command == nil {
    scanner.fail(CommandError("missing required key-value pair 'action=..'\n"))
  }
  try scanner.finish()
}
