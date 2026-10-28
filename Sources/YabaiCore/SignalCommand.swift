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
      let (signal, event) = try parseAddition(&message)
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

  /// Reports field problems together, then constructs a complete definition.
  private static func parseAddition(_ message: inout Message)
    throws(CommandError) -> (EventSignal, SignalType)
  {
    var scanner = KeyValueScanner(first: message.take())
    var hasSignalType = false
    var event: SignalType?
    var command: String?
    var label: String?
    var app: RulePattern?
    var title: RulePattern?
    var active: Bool?

    while let pair = scanner.next(&message) {
      let key = pair.key
      let value = pair.value
      var isFilter = false
      var validValue = true
      var validPattern = true

      if key.equals("label") {
        label = value.string
      } else if key.equals("app") {
        isFilter = true
        app = RulePattern(value, exclude: pair.exclusion)
        validPattern = app?.regex != nil
      } else if key.equals("title") {
        isFilter = true
        title = RulePattern(value, exclude: pair.exclusion)
        validPattern = title?.regex != nil
      } else if key.equals("active") {
        if value.equals("yes") {
          active = true
        } else if value.equals("no") {
          active = false
        } else {
          validValue = false
        }
      } else if key.equals("action") {
        command = value.string
      } else if key.equals("event") {
        hasSignalType = true
        event = SignalType(name: value)
        validValue = event != nil
      } else {
        scanner.unknownKey(key)
        continue
      }

      scanner.check(pair, filter: isFilter, validValue: validValue, validPattern: validPattern)
    }

    if !hasSignalType { scanner.fail(CommandError("missing required key-value pair 'event=..'\n")) }
    if command == nil {
      scanner.fail(CommandError("missing required key-value pair 'action=..'\n"))
    }
    try scanner.finish()
    guard let event, let command else {
      preconditionFailure("A successful signal parse requires an event and action")
    }
    var signal = EventSignal(command: command)
    signal.label = label
    signal.app = app
    signal.title = title
    signal.active = active
    return (signal, event)
  }
}
