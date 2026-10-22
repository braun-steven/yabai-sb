import YabaiCore

//
// NOTE: checkMessage parses a message the way its handler does and writes the failures the handler would write, but
// applies nothing: the config Change closures are dropped (checkConfigMessage), rules and signals are parsed and not
// added, removed or applied. Failures that need the current state or an applied change are not found here: a --space
// selector, a rule or signal index or label that does not exist, a space or display label that does not exist, and what a
// config Change throws when applied. Those stay for handleMessage. The domains that act on the session (space, window, display,
// query) are not parsed at all; the check reports a note for them.
//

/// What checkMessage found. `failures` are the failure texts handleMessage writes for the same message, in order. A text
/// is the bytes after the failure byte with its trailing newline (the text of CommandError), so a line to print drops
/// the last byte. `notes` say what the check does not cover; they are not failures.
struct MessageCheck {
  var failures: [String] = []
  var notes: [String] = []
}

/// The selector context of a check. Every lookup finds one placeholder id, so a selector is parsed for its syntax and
/// resolves without reading the session (SkyLight or the managers). A selector that the session would not find, such as
/// a space label that does not exist, is therefore not reported.
@WM struct CheckSelectorContext: @WM SelectorContext {
  typealias Window = Yabai.Window

  static let placeholderDisplay = DisplayID(0xFFFF_0000)
  static let placeholderSpace = SpaceID(0xFFFF_0000)

  var activeDisplay: DisplayID? { Self.placeholderDisplay }
  var activeSpace: SpaceID? { Self.placeholderSpace }
  func actingWindow() -> Window? { nil }

  func display(_ query: DisplayQuery) -> DisplayID? { Self.placeholderDisplay }
  func displayLabel(_ label: Token) -> DisplayID? { Self.placeholderDisplay }
  func space(_ query: SpaceQuery) -> SpaceID? { Self.placeholderSpace }
  func spaceLabel(_ label: Token) -> SpaceID? { Self.placeholderSpace }
  func window(_ query: WindowQuery<Window>) -> Window? { nil }
}

/// Checks a message without applying it. Pass a copy of the message that handleMessage would get: the check reads it.
@WM func checkMessage(_ message: inout Message) -> MessageCheck {
  var check = MessageCheck()
  var response = Response()
  do {
    try checkDomain(&check, &response, &message)
  } catch {
    response.fail(error)
  }
  check.failures = failureTexts(response.bytes)
  return check
}

/// Mirrors handleDomain: the same domain tokens in the same order.
@WM private func checkDomain(
  _ check: inout MessageCheck, _ response: inout Response, _ message: inout Message
) throws(CommandError) {
  let domain = message.next()

  if domain.equals(Domain.config) {
    // NOTE: A reload in a yabairc runs the yabairc again, so a bare `config --reload` there loops. The check does not
    // run it, and it counts the line as skipped, because the reload may sit behind a condition that stops it.
    if message.peek().equals("--reload") {
      check.notes.append(
        "reloads the yabairc, which runs it again: a bare config --reload there loops")
    }
    try checkConfigMessage(&response, domain, &message)
  } else if domain.equals(Domain.rule) {
    try checkRuleMessage(&message)
  } else if domain.equals(Domain.signal) {
    try checkSignalMessage(&message)
  } else if domain.equals(BatchMessage.domain) {
    // NOTE: The commands of a batch are read from their own tokens when the batch runs (handleDomainBatch), which
    // the check does not do, so it reports them as not checked. A malformed batch is still reported when it runs.
    check.notes.append("not checked: batch commands are checked when they run")
  } else if domain.equals(Domain.display) || domain.equals(Domain.space)
    || domain.equals(Domain.window) || domain.equals(Domain.query)
  {
    check.notes.append("not checked: \(domain.string) commands act on the current session")
  } else {
    throw CommandError("unknown domain '\(domain)'\n")
  }
}

//
// NOTE: `rule --apply <label>` with inline values runs the inline rule only when no rule has the label; its parse error
// is thrown then, and a label that exists ignores it (handleDomainRule). The label is looked up here, which reads the
// rules without changing them.
//

/// Parses a rule message as handleDomainRule does, without adding, removing or applying a rule.
@WM private func checkRuleMessage(_ message: inout Message) throws(CommandError) {
  let command = try RuleCommand.parse(&message, CheckSelectorContext())
  if case .apply(.labelOrInline(let label, .failure(let error))) = command,
    !WindowManager.shared.rules.contains(where: { $0.label == label.string })
  {
    throw error
  }
}

/// Parses a signal message as handleDomainSignal does, without adding or removing a signal.
@WM private func checkSignalMessage(_ message: inout Message) throws(CommandError) {
  _ = try SignalCommand.parse(&message)
}

/// The failure texts of a response. Each failure starts with the failure byte. A check writes nothing else: it never
/// prints, so no response text is mixed in.
private func failureTexts(_ bytes: [UInt8]) -> [String] {
  bytes.split(separator: Response.failureByte, omittingEmptySubsequences: false).dropFirst().map {
    String(decoding: $0, as: UTF8.self)
  }
}
