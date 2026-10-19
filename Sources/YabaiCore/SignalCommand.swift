/// A selector accepted by `signal --remove`.
public enum SignalSelector
{
    case index(Int)
    case label(Token)
}

/// A parsed command of the signal domain. Event remains generic so YabaiCore does not depend on daemon-owned signal
/// registration details.
public enum SignalCommand<Event>
{
    case add(EventSignal, Event)
    case remove(SignalSelector)
    case list

    private enum Name: String, CaseIterable
    {
        case add = "--add"
        case remove = "--remove"
        case list = "--list"

        init?(_ token: Token)
        {
            guard let name = Self.allCases.first(where: { token.equals($0.rawValue) }) else { return nil }
            self = name
        }
    }

    /// Parses one signal command and resolves its event name with the supplied lookup.
    public static func parse(_ message: inout some TokenSource, eventType: (Token) -> Event?) throws(CommandError) -> SignalCommand<Event>
    {
        let command = message.next()
        guard let name = Name(command) else { throw CommandError.unknownCommand(Token(Domain.signal), command) }

        switch name {
        case .add:
            var signal = EventSignal()
            var event: Event?
            try parseSignal(&message, &signal, &event, eventType: eventType)
            guard let event else { preconditionFailure("parseSignal requires an event") }
            return .add(signal, event)

        case .remove:
            let selector = message.next()
            switch selector.value {
            case .int(let index): return .remove(.index(Int(index)))
            case .string:        return .remove(.label(selector))
            default:             throw CommandError("value '\(selector)' is not a valid option for SIGNAL_SEL\n")
            }

        case .list:
            return .list
        }
    }
}
