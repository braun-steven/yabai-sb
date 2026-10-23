import Foundation
import Logging
import YabaiCore

//
// NOTE: The reconcile of the static config (ConfigLoader.reconcile). A document is applied as the difference from the
// running state, so a reload changes only what differs and the layouts survive.
//
// - Options: a message runs when its value differs. The running value is the option's own print (`config <name>`),
//   compared with the lowered word (sameConfigValue). A tab bar font runs while no font is loaded, so the startup always
//   sets it (C3.1). An option that the applied document set and the new one does not goes back to its default, the
//   value printed before any file value (defaultWords).
// - Spaces: a space is addressed by its index, as the file gives it. Its label, pin and per-space options run when they
//   differ. A per-space option also runs when its override is missing, so an equal value is still recorded as the
//   space's own, as `config --space` records it. A removed entry removes its pin and label and gives its per-space values
//   back to the global value (resetSpaceOption): no message expresses that. Such a space is found by its label, which
//   needs no window server. Spaces are never created or destroyed here (AGENTS.md).
// - Rules and signals: the file's lists are parsed as `rule --add` and `signal --add` parse them, without side effects,
//   and added as those add them (a rule replaces the rule with its label). When the result differs from the running list,
//   the running list is replaced; otherwise it is left alone, so the rule indices stay.
// - Steps: startup calls reconcile once per ConfigStep, at its place in the startup sequence (Yabai.swift), so the
//   first call sees the empty running state and nothing is removed. A reload runs the steps in order with nothing in
//   between. `applied` is set by the last step.
//
// Every message that runs goes through handleMessage with its lowered words, one parser per setting.
//

/// The printed value of a config message (`config <name>`, `config --space <index> <name>`), or nil when it failed.
@WM func printedConfigValue(_ arguments: [String]) -> String? {
  var response = Response()
  var message = configMessage(arguments)
  handleMessage(&response, &message)
  guard failureTexts(response.bytes).isEmpty else { return nil }
  return String(decoding: response.bytes, as: UTF8.self)
    .trimmingCharacters(in: .whitespacesAndNewlines)
}

/// Whether a printed value and a lowered word name the same value. A color prints without leading zeros (0xff...), so
/// colors are compared as numbers. A float prints with fixed decimals (4.0000, or 0.250000 for %f), so the word is
/// formatted with the same number of decimals and the strings are compared: a file value with more decimals than the
/// print is then equal to the running value. Other values must be equal.
func sameConfigValue(_ printed: String, _ word: String) -> Bool {
  if printed == word { return true }
  if printed.hasPrefix("0x") && word.hasPrefix("0x") {
    guard let a = UInt64(printed.dropFirst(2), radix: 16),
      let b = UInt64(word.dropFirst(2), radix: 16)
    else { return false }
    return a == b
  }
  guard let a = Double(printed), let b = Double(word) else { return false }

  guard let point = printed.firstIndex(of: ".") else { return a == b }
  let digits = printed[printed.index(after: point)...]
  guard !digits.isEmpty, digits.allSatisfy({ $0 >= "0" && $0 <= "9" }) else { return a == b }
  return cFormat("%.\(digits.count)f", b) == printed
}

/// Runs one message through handleMessage, as the daemon runs a `yabai -m` message, and returns its failures. Each failure
/// is logged with the key path of its setting, or with the message when it has none (a reset).
@WM @discardableResult func runConfigMessage(
  _ arguments: [String], keyPath: String, kind: ConfigEntry.Kind
) -> Int {
  if Headless.isEnabled {
    Headless.record(configEntries: [ConfigEntry(arguments: arguments, keyPath: keyPath, kind: kind)]
    )
  }

  var response = Response()
  var message = configMessage(arguments)
  handleMessage(&response, &message)

  let texts = failureTexts(response.bytes)
  let source = keyPath.isEmpty ? arguments.joined(separator: " ") : keyPath
  for text in texts {
    Logger.daemon.warning("config file: \(source): \(text.trimmingCharacters(in: .newlines))")
  }
  return texts.count
}

extension ConfigLoader {
  /// The printed value of each option of a new daemon. The first reconcile captures them, before it applies anything.
  @WM func defaultWords() -> [ConfigName: String] {
    if let defaults { return defaults }

    var words: [ConfigName: String] = [:]
    for name in ConfigName.allCases {
      words[name] = printedConfigValue(["config", name.rawValue])
    }
    defaults = words
    return words
  }

  /// Applies the document for one step against the running state (see the NOTE above). Returns the number of messages
  /// that failed. The last step records the document as applied.
  @WM func reconcile(to document: ConfigDocument, step: ConfigStep) -> Int {
    let defaults = defaultWords()

    let failures: Int
    switch step {
    case .settings, .managerSettings:
      failures = reconcileOptions(document, step: step, applied: applied, defaults: defaults)
    case .spaces: failures = reconcileSpaces(document, applied: applied)
    case .rulesAndSignals: failures = reconcileRulesAndSignals(document)
    }

    if step == ConfigStep.allCases.last { applied = document }
    return failures
  }
}

/// Whether the message that sets an option to `word` must run. A tab bar font runs while none is loaded: the reload
/// clears the font (resetConfigToStartupDefaults), and the bars then use the fallback until a font is set.
@WM private func optionNeedsApply(_ name: ConfigName, word: String) -> Bool {
  if name == .tabBarFont && WindowManager.shared.tabBarFont == nil { return true }
  guard let printed = printedConfigValue(["config", name.rawValue]) else { return true }
  return !sameConfigValue(printed, word)
}

/// The global options of one step: the ones the document sets and the ones that the applied document set but it does not,
/// which go back to their default.
@WM private func reconcileOptions(
  _ document: ConfigDocument, step: ConfigStep, applied: ConfigDocument?,
  defaults: [ConfigName: String]
) -> Int {
  var failures = 0

  if let applied {
    let kept = Set(document.options.map(\.name))
    for option in applied.options where !kept.contains(option.name) {
      let entry = ConfigEntry(
        arguments: ["config", option.name.rawValue], keyPath: option.keyPath, kind: .option)
      guard configStep(of: entry) == step, let word = defaults[option.name] else { continue }
      if optionNeedsApply(option.name, word: word) {
        failures += runConfigMessage(
          ["config", option.name.rawValue, word], keyPath: option.keyPath, kind: .option)
      }
    }
  }

  for entry in document.lowered() where entry.kind == .option || entry.kind == .spaceLayout {
    guard configStep(of: entry) == step, entry.arguments.count > 1,
      let name = ConfigName(rawValue: entry.arguments[1])
    else { continue }

    let word = entry.arguments.dropFirst(2).joined(separator: " ")
    if optionNeedsApply(name, word: word) {
      failures += runConfigMessage(entry.arguments, keyPath: entry.keyPath, kind: entry.kind)
    }
  }
  return failures
}

/// The per-space options that a view records an override for, as `config --space` does; nil for the others.
private func spaceOverride(_ name: ConfigName) -> ViewOverrides? {
  switch name {
  case .layout: ViewOverrides.layout
  case .autoPadding: ViewOverrides.autoPadding
  default: viewSpacing(name)?.override
  }
}

/// The padding and gap that a per-space option sets, nil for the other options.
private func viewSpacing(_ name: ConfigName) -> ViewSpacing? {
  switch name {
  case .topPadding: ViewSpacing.topPadding
  case .bottomPadding: ViewSpacing.bottomPadding
  case .leftPadding: ViewSpacing.leftPadding
  case .rightPadding: ViewSpacing.rightPadding
  case .windowGap: ViewSpacing.windowGap
  default: nil
  }
}

/// The space at a mission-control index, nil when there is none. It reads the window server, so the tests address spaces
/// by label.
@WM func spaceID(atIndex index: Int) -> SpaceID? {
  try? SpaceSelector.missionControl(index).resolve(acting: nil, CSelectorContext())
}

/// The uuid of the display that a pin selector names now, nil when it names none.
@WM private func pinnedDisplayUUID(_ selector: String) -> String? {
  guard let display = DisplaySelector(Token(selector)),
    let target = try? display.resolve(acting: DisplayID.active, CSelectorContext())
  else { return nil }
  return target.uuid
}

/// Whether a per-space option message must run: its value differs from the space's, or the space has no override for it.
@WM private func spaceOptionNeedsApply(
  _ name: ConfigName, word: String, index: Int, sid: SpaceID
) -> Bool {
  if let override = spaceOverride(name),
    !SpaceManager.shared.view(for: sid).overrides.contains(override)
  {
    return true
  }
  guard let printed = printedConfigValue(["config", "--space", "\(index)", name.rawValue]) else {
    return true
  }
  return !sameConfigValue(printed, word)
}

/// Gives a per-space option back to the global value: its override is removed and the space follows the defaults again.
/// This changes the view directly, since no message removes an override.
@WM func resetSpaceOption(_ name: ConfigName, on sid: SpaceID) {
  let manager = SpaceManager.shared
  let view = manager.view(for: sid)
  if name == .layout {
    // NOTE: As `config --space layout` does, a macOS fullscreen space keeps its layout.
    guard sid.isUser else { return }
    view.overrides.remove(.layout)
    manager.setLayout(Config.current.space.layout, for: sid)
  } else if name == .autoPadding {
    view.overrides.remove(.autoPadding)
    manager.applyAutoPadding(Config.current.space.autoPadding, to: view)
  } else if let spacing = viewSpacing(name) {
    view.overrides.remove(spacing.override)
    let value = Config.current.space[keyPath: spacing.spaceDefault]
    if view[keyPath: spacing.view] != value {
      view[keyPath: spacing.view] = value
      view.updateAndFlush()
    }
  }
}

/// Removes what the applied [[space]] entry set and the new document does not keep: its pin, its label, and its per-space
/// values. The space is found by the label when the entry has one, else by its index.
@WM private func removeSpaceEntry(_ old: SpaceEntry, kept: SpaceEntry?) -> Int {
  let manager = SpaceManager.shared

  let sid: SpaceID?
  let selector: String
  if let label = old.label, let labelled = manager.labels.id(named: label) {
    sid = labelled
    selector = label
  } else {
    sid = spaceID(atIndex: old.index)
    selector = "\(old.index)"
  }
  guard let sid else { return 0 }

  var failures = 0
  // NOTE: The pin goes first. Removing the label drops a pin too, but an explicit unpin is what the pin reads.
  if let label = old.label, old.pin != nil, kept?.pin == nil,
    manager.pins.display(of: label) != nil
  {
    failures += runConfigMessage(
      ["space", label, "--pin"], keyPath: "\(old.keyPath).pin", kind: .space)
  }
  if let label = old.label, kept?.label != label, manager.labels.name(of: sid) == label {
    failures += runConfigMessage(
      ["space", selector, "--label"], keyPath: "\(old.keyPath).label", kind: .space)
  }
  for option in old.options where !(kept?.options.contains { $0.name == option.name } ?? false) {
    resetSpaceOption(option.name, on: sid)
  }
  return failures
}

/// The messages of one [[space]] entry, its label, pin and per-space options in that order, each only when it differs.
@WM private func reconcileSpace(_ space: SpaceEntry, _ entries: [ConfigEntry]) -> Int {
  let manager = SpaceManager.shared

  guard let sid = spaceID(atIndex: space.index) else {
    // NOTE: No space has the index. The messages run as they are, so their failures are reported; none creates a space.
    var failures = 0
    for entry in entries {
      failures += runConfigMessage(entry.arguments, keyPath: entry.keyPath, kind: entry.kind)
    }
    return failures
  }

  var failures = 0
  for entry in entries {
    let value = entry.arguments.last ?? ""

    if entry.keyPath == "\(space.keyPath).label" {
      if manager.labels.name(of: sid) != value {
        failures += runConfigMessage(entry.arguments, keyPath: entry.keyPath, kind: entry.kind)
      }
    } else if entry.keyPath == "\(space.keyPath).pin" {
      let current = manager.labels.name(of: sid).flatMap { manager.pins.display(of: $0) }
      if current == nil || current != pinnedDisplayUUID(value) {
        failures += runConfigMessage(entry.arguments, keyPath: entry.keyPath, kind: entry.kind)
      }
    } else if entry.arguments.count > 3, let name = ConfigName(rawValue: entry.arguments[3]) {
      let word = entry.arguments.dropFirst(4).joined(separator: " ")
      if spaceOptionNeedsApply(name, word: word, index: space.index, sid: sid) {
        failures += runConfigMessage(entry.arguments, keyPath: entry.keyPath, kind: entry.kind)
      }
    }
  }
  return failures
}

@WM private func reconcileSpaces(_ document: ConfigDocument, applied: ConfigDocument?) -> Int {
  var failures = 0

  if let applied {
    for old in applied.spaces {
      failures += removeSpaceEntry(old, kept: document.spaces.first { $0.index == old.index })
    }
  }

  let spaceEntries = document.lowered().filter { $0.kind == .space }
  for space in document.spaces {
    let entries = spaceEntries.filter { $0.keyPath.hasPrefix(space.keyPath + ".") }
    failures += reconcileSpace(space, entries)
  }
  return failures
}

/// The rules that the entries add, as `rule --add` stores them: a rule replaces the rule with its label and is appended.
/// Nil when an entry does not parse; its add then fails when it runs.
@WM private func parsedRules(_ entries: [ConfigEntry]) -> [Rule]? {
  var rules: [Rule] = []
  for entry in entries {
    var message = configMessage(Array(entry.arguments.dropFirst()))
    guard case .add(let rule)? = try? RuleCommand.parse(&message, CSelectorContext()) else {
      return nil
    }
    if let label = rule.label { rules.removeAll { $0.label == label } }
    rules.append(rule)
  }
  return rules
}

/// The signals that the entries add, as `signal --add` stores them. Nil when an entry does not parse.
@WM private func parsedSignals(_ entries: [ConfigEntry]) -> SignalTable? {
  var table = SignalTable()
  for entry in entries {
    var message = configMessage(Array(entry.arguments.dropFirst()))
    guard case .add(let signal, let type)? = try? SignalCommand.parse(&message) else { return nil }
    table.add(signal, type)
  }
  return table
}

@WM private func reconcileRulesAndSignals(_ document: ConfigDocument) -> Int {
  var failures = 0
  let entries = document.lowered()
  let ruleEntries = entries.filter { $0.kind == .rule }
  let signalEntries = entries.filter { $0.kind == .signal }

  if parsedRules(ruleEntries) != WindowManager.shared.rules {
    WindowManager.shared.rules = []
    for entry in ruleEntries {
      failures += runConfigMessage(entry.arguments, keyPath: entry.keyPath, kind: entry.kind)
    }
  }

  if parsedSignals(signalEntries) != EventSignals.shared.table {
    EventSignals.shared.table = SignalTable()
    for entry in signalEntries {
      failures += runConfigMessage(entry.arguments, keyPath: entry.keyPath, kind: entry.kind)
    }
  }
  return failures
}
