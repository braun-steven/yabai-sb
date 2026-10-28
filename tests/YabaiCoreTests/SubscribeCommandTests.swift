import Testing

@testable import YabaiCore

//
// NOTE: `SubscribeCommand.parse` reads the event names after the domain token. No name means every event, and the
// result is in the order of SignalType whatever the order of the names.
//

/// A subscribe message with these event names, read as the daemon reads it: the domain token is consumed first, as
/// handleDomain does, and then the names are parsed.
private func parsed(_ eventNames: [String]) throws(CommandError) -> [SignalType] {
  var message = Message(commandTokens: [Token(Domain.subscribe)] + eventNames.map { Token($0) })
  _ = message.next()
  return try SubscribeCommand.parse(&message)
}

@Suite struct SubscribeCommandTests {
  @Test func noNameSubscribesToEveryEvent() throws {
    #expect(try parsed([]) == SignalType.allCases)
  }

  @Test func namesKeepTheOrderOfTheEventsAndDropRepeats() throws {
    let types = try parsed(["space_changed", "window_focused", "space_changed"])
    #expect(types == [.windowFocused, .spaceChanged])
  }

  @Test func subscribedLineListsTheNamesInOrder() throws {
    let line = SubscribeCommand.subscribedLine(try parsed(["window_focused", "space_changed"]))
    let json = try JSON.encode(line)
    #expect(
      String(decoding: json, as: UTF8.self)
        == "{\"subscribed\":[\"window_focused\",\"space_changed\"]}")
  }

  @Test func everyEventNameIsAcceptedAsItIsInSignalAdd() throws {
    for type in SignalType.allCases {
      #expect(try parsed([type.name]) == [type])
    }
  }

  @Test(arguments: [
    (
      "bogus",
      "unknown event 'bogus' for domain 'subscribe'; expected one of: application_launched, "
    ),
    ("Window_Focused", "unknown event 'Window_Focused' for domain 'subscribe'; expected one of: "),
    ("", "unknown event '' for domain 'subscribe'; expected one of: "),
  ])
  func unknownNameFailsWithTheValidNames(_ name: String, _ prefix: String) {
    do {
      _ = try parsed(["window_focused", name])
      Issue.record("an unknown event was accepted")
    } catch {
      let text = error.description
      #expect(text.hasPrefix(prefix))
      #expect(text.hasSuffix("system_woke, config_loaded\n"))
    }
  }
}
