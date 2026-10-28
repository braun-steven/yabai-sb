//
// NOTE: `yabai -m subscribe [<event>…]` names the events of a stream: the message is parsed here, and the daemon keeps
// the socket open for them (Response.Disposition.subscribe). The names are the
// event names of `signal --add event=…`, so the parser is the same SignalType lookup.
//

/// The first line of a subscription: `{"subscribed":["window_focused",…]}`, followed by a newline when it is written.
public struct SubscribedLine: Encodable, Equatable {
  public let subscribed: [String]

  public init(subscribed: [String]) {
    self.subscribed = subscribed
  }
}

/// The events named by a subscribe message.
public enum SubscribeCommand {
  /// Parses the event names after the domain token. No name subscribes to every event. The result is in the order of
  /// SignalType, without duplicates, so the first line of a subscription does not depend on the order of the names.
  ///
  /// Fails at the first name that is not an event, and the failure lists the events, as the P9.1 failures do.
  public static func parse(_ message: inout Message) throws(CommandError) -> [SignalType] {
    var named: Set<SignalType> = []
    while let name = message.take() {
      guard let type = SignalType(name: name) else {
        let events = SignalType.allCases.map(\.name)
        throw CommandError(
          "unknown event '\(name)' for domain 'subscribe'; expected \(expectedChoices(events))\n")
      }
      named.insert(type)
    }

    if named.isEmpty { return SignalType.allCases }
    return SignalType.allCases.filter { named.contains($0) }
  }

  /// The first line of a subscription to these types, as it is written to the client.
  public static func subscribedLine(_ types: [SignalType]) -> SubscribedLine {
    SubscribedLine(subscribed: types.map(\.name))
  }
}
