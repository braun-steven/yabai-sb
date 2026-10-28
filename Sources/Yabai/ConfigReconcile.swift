import Foundation
import Logging
import SortedCollections
import YabaiCore

//
// NOTE: The reconcile of the static config (ConfigLoader.reconcile). A document is applied as the difference from the
// running state, so a reload changes only what differs and the layouts survive.
//
// - Options: a message runs when its value differs. The running value is the option's own print (`config <name>`),
//   compared with the lowered word (sameConfigValue). A tab bar font runs while no font is loaded (tabBarFont is nil),
//   even at its name. This is a guard, not a reload step: WindowManager.initialize loads the default font before the
//   startup sets the file's font, so only a manager without a font (a test fixture) takes this path. An option that the
//   applied document set and the new one does not goes back to its default, the value printed before any file value
//   (defaultWords).
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

/// What a reconcile did. `changes` counts the messages that ran without a failure, each direct reset of a per-space option
/// (resetSpaceOption), and each rule or signal list that was replaced (once for the replacement, and once more for each of
/// its entries, which run as messages). `failures` counts the failures of the messages that ran; each one is logged.
struct ConfigReconcileResult: Equatable, Sendable {
  var changes = 0
  var failures = 0
  /// One `<key path>: <failure>` line per failure, as the log has it.
  var failureLines: [String] = []

  static func += (total: inout ConfigReconcileResult, part: ConfigReconcileResult) {
    total.changes += part.changes
    total.failures += part.failures
    total.failureLines += part.failureLines
  }
}

/// The printed value of a config message (`config <name>`, `config --space <index> <name>`), or nil when it failed.
@WM func printedConfigValue(_ arguments: [String]) -> String? {
  var response = Response()
  var message = configMessage(arguments)
  handleMessage(&response, &message)
  guard failureTexts(response.bytes).isEmpty else { return nil }
  return String(decoding: response.bytes, as: UTF8.self)
    .trimmingCharacters(in: .whitespacesAndNewlines)
}

/// The kind of each option's value (ConfigOption.kind).
@WM private let configOptionKinds = Dictionary(
  uniqueKeysWithValues: configOptions.map { ($0.name, $0.kind) })

/// A word of an option of `kind`, printed or lowered, read as a document value: on and off as booleans, numbers and
/// `0x` colors by value, `space_layout` as its words (`off` is none). Nil when the word does not read as that kind.
func configValue(_ word: String, kind: ConfigOptionKind) -> ConfigValue? {
  switch kind {
  case .bool:
    if word == Argument.on { return .bool(true) }
    if word == Argument.off { return .bool(false) }
    return nil
  case .integer:
    return Int(word).map { ConfigValue.integer($0) }
  case .color:
    guard word.hasPrefix("0x"), let value = UInt32(word.dropFirst(2), radix: 16) else {
      return nil
    }
    return .integer(Int(value))
  case .float:
    return Double(word).map { ConfigValue.float($0) }
  case .text:
    return .string(word)
  case .strings:
    if word == Argument.off { return .strings([]) }
    return .strings(word.split(separator: " ").map(String.init))
  }
}

/// The printed value of option `name` as a document value (configValue), in the form the option takes back.
@WM func printedValue(_ printed: String, of name: ConfigName) -> ConfigValue? {
  // NOTE: focus_follows_mouse prints the disabled mode as `disabled` (focusFollowsMouseOption), and takes it as `off`. No
  // other option prints a value it does not take.
  if name == .focusFollowsMouse && printed == FocusFollowsMouse.disabled.rawValue {
    return .string(Argument.off)
  }
  return configOptionKinds[name].flatMap { configValue(printed, kind: $0) }
}

/// Whether the printed value of option `name` and a lowered word name the same value. Both are read as the option's kind
/// (printedValue, configValue), so colors and numbers compare by value; a float option holds a Float, so 0.1 in the file
/// equals the running value that prints as 0.1. A word that does not read as the kind must equal the print.
@WM func sameConfigValue(_ name: ConfigName, printed: String, word: String) -> Bool {
  if printed == word { return true }
  guard let kind = configOptionKinds[name], let running = printedValue(printed, of: name),
    let file = configValue(word, kind: kind)
  else { return false }
  if case .float(let a) = running, case .float(let b) = file { return Float(a) == Float(b) }
  return running == file
}

/// Runs one message through handleMessage, as the daemon runs a `yabai -m` message, and returns what it did: one change when
/// it ran without a failure, and its failures. Each failure is logged with the key path of its setting, or with the message
/// when it has none (a reset).
@WM @discardableResult func runConfigMessage(_ entry: ConfigEntry) -> ConfigReconcileResult {
  if Headless.isEnabled {
    Headless.record(configEntries: [entry])
  }

  var response = Response()
  var message = configMessage(entry.arguments)
  handleMessage(&response, &message)

  let texts = failureTexts(response.bytes)
  let source = entry.keyPath.isEmpty ? entry.arguments.joined(separator: " ") : entry.keyPath
  let lines = texts.map { "\(source): \($0.trimmingCharacters(in: .newlines))" }
  for line in lines {
    Logger.daemon.warning("config file: \(line)")
  }
  return ConfigReconcileResult(
    changes: texts.isEmpty ? 1 : 0, failures: texts.count, failureLines: lines)
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

  /// Applies the document for one step against the running state (see the NOTE above), and returns what it did. The last
  /// step records the document as applied.
  @WM func reconcile(to document: ConfigDocument, step: ConfigStep) -> ConfigReconcileResult {
    let defaults = defaultWords()
    let entries = document.lowered().filter { configStep(of: $0.target) == step }

    let result: ConfigReconcileResult
    switch step {
    case .settings, .managerSettings:
      result = reconcileOptions(
        document, entries, step: step, applied: applied, defaults: defaults)
    case .spaces: result = reconcileSpaces(document, entries, applied: applied)
    case .rulesAndSignals: result = reconcileRulesAndSignals(entries, applied: applied)
    }

    if step == ConfigStep.allCases.last { applied = document }
    return result
  }
}

/// Whether the message that sets an option to `word` must run. A tab bar font runs while none is loaded, and the bars
/// then use the fallback until a font is set.
@WM private func optionNeedsApply(_ name: ConfigName, word: String) -> Bool {
  if name == .tabBarFont && WindowManager.shared.tabBarFont == nil { return true }
  guard let printed = printedConfigValue(["config", name.rawValue]) else { return true }
  return !sameConfigValue(name, printed: printed, word: word)
}

/// The global options of one step (`entries`, the document's entries of the step): the ones the document sets and the
/// ones that the applied document set but it does not, which go back to their default.
@WM private func reconcileOptions(
  _ document: ConfigDocument, _ entries: [ConfigEntry], step: ConfigStep,
  applied: ConfigDocument?, defaults: [ConfigName: String]
) -> ConfigReconcileResult {
  var result = ConfigReconcileResult()

  if let applied {
    let kept = Set(document.options.map(\.name))
    for option in applied.options where !kept.contains(option.name) {
      guard configStep(of: .option(option.name)) == step, let word = defaults[option.name] else {
        continue
      }
      if optionNeedsApply(option.name, word: word) {
        result += runConfigMessage(.option(option.name, word, keyPath: option.keyPath))
      }
    }
  }

  for entry in entries {
    guard case .option(let name) = entry.target else { continue }
    if optionNeedsApply(name, word: entry.value) {
      result += runConfigMessage(entry)
    }
  }
  return result
}

/// The per-space options that a view records an override for, as `config --space` does; nil for the others.
func spaceOverride(_ name: ConfigName) -> ViewOverrides? {
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
  return !sameConfigValue(name, printed: printed, word: word)
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
@WM private func removeSpaceEntry(_ old: SpaceEntry, kept: SpaceEntry?) -> ConfigReconcileResult {
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
  guard let sid else { return ConfigReconcileResult() }

  var result = ConfigReconcileResult()
  // NOTE: The pin goes first. Removing the label drops a pin too, but an explicit unpin is what the pin reads.
  if let label = old.label, old.pin != nil, kept?.pin == nil,
    manager.pins.display(of: label) != nil
  {
    result += runConfigMessage(
      ConfigEntry(
        target: .spacePin(index: old.index), value: "", arguments: ["space", label, "--pin"],
        keyPath: "\(old.keyPath).pin"))
  }
  if let label = old.label, kept?.label != label, manager.labels.name(of: sid) == label {
    result += runConfigMessage(
      ConfigEntry(
        target: .spaceLabel(index: old.index), value: "",
        arguments: ["space", selector, "--label"],
        keyPath: "\(old.keyPath).label"))
  }
  for option in old.options where !(kept?.options.contains { $0.name == option.name } ?? false) {
    result.changes += 1
    resetSpaceOption(option.name, on: sid)
  }
  return result
}

/// The messages of the [[space]] entry with `index`, its label, pin and per-space options in that order, each only when it
/// differs.
@WM private func reconcileSpace(index: Int, _ entries: [ConfigEntry]) -> ConfigReconcileResult {
  let manager = SpaceManager.shared

  guard let sid = spaceID(atIndex: index) else {
    // NOTE: No space has the index. The messages run as they are, so their failures are reported; none creates a space.
    var result = ConfigReconcileResult()
    for entry in entries {
      result += runConfigMessage(entry)
    }
    return result
  }

  var result = ConfigReconcileResult()
  for entry in entries {
    let needsApply: Bool
    switch entry.target {
    case .spaceLabel:
      needsApply = manager.labels.name(of: sid) != entry.value
    case .spacePin:
      let current = manager.labels.name(of: sid).flatMap { manager.pins.display(of: $0) }
      needsApply = current == nil || current != pinnedDisplayUUID(entry.value)
    case .spaceOption(_, let name):
      needsApply = spaceOptionNeedsApply(name, word: entry.value, index: index, sid: sid)
    case .option, .rule, .signal:
      needsApply = false
    }
    if needsApply {
      result += runConfigMessage(entry)
    }
  }
  return result
}

@WM private func reconcileSpaces(
  _ document: ConfigDocument, _ entries: [ConfigEntry], applied: ConfigDocument?
) -> ConfigReconcileResult {
  var result = ConfigReconcileResult()

  if let applied {
    for old in applied.spaces {
      result += removeSpaceEntry(old, kept: document.spaces.first { $0.index == old.index })
    }
  }

  for space in document.spaces {
    result += reconcileSpace(index: space.index, entries.filter { $0.spaceIndex == space.index })
  }
  return result
}

extension ConfigEntry {
  /// The space index of a [[space]] entry's message; nil for the other messages.
  fileprivate var spaceIndex: Int? {
    switch target {
    case .spaceLabel(let index), .spacePin(let index), .spaceOption(let index, _): index
    case .option, .rule, .signal: nil
    }
  }
}

/// The rules that the entries add, as `rule --add` stores them: a labeled replacement keeps its index.
/// Nil when an entry does not parse; its add then fails when it runs.
@WM private func parsedRules(_ entries: [ConfigEntry]) -> [Rule]? {
  var rules = RuleSet()
  for entry in entries {
    var message = configMessage(Array(entry.arguments.dropFirst()))
    guard case .add(let rule)? = try? RuleCommand.parse(&message, CSelectorContext()) else {
      return nil
    }
    rules.add(rule)
  }
  return rules.definitions
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

/// Whether the running rules are the file's rules (`fileRules`, nil when one does not parse). A one-shot rule is removed
/// once it matched a window, so the rules without one-shot rules are compared in order, and the file's one-shot rules
/// either with the running ones that did not match yet or with those of the last applied document (`applied`): a one-shot
/// rule that was used up is no override, and it is added again only when the file's one-shot rules change.
@WM private func rulesMatchFile(_ fileRules: [Rule]?, applied: ConfigDocument?) -> Bool {
  guard let fileRules else { return false }
  let running = WindowManager.shared.rules
  guard fileRules.filter({ !$0.oneShot }) == running.filter({ !$0.oneShot }) else { return false }

  let fileOneShot = fileRules.filter(\.oneShot)
  if fileOneShot == running.unmatchedOneShotRules { return true }
  let appliedRules =
    applied.flatMap { parsedRules($0.lowered().filter { $0.target == .rule }) } ?? []
  return fileOneShot == appliedRules.filter(\.oneShot)
}

@WM private func reconcileRulesAndSignals(_ entries: [ConfigEntry], applied: ConfigDocument?)
  -> ConfigReconcileResult
{
  var result = ConfigReconcileResult()
  let ruleEntries = entries.filter { $0.target == .rule }
  let signalEntries = entries.filter { $0.target == .signal }

  if !rulesMatchFile(parsedRules(ruleEntries), applied: applied) {
    WindowManager.shared.rules = []
    result.changes += 1
    for entry in ruleEntries {
      result += runConfigMessage(entry)
    }
  }

  if parsedSignals(signalEntries) != EventSignals.shared.table {
    EventSignals.shared.table = SignalTable()
    result.changes += 1
    for entry in signalEntries {
      result += runConfigMessage(entry)
    }
  }
  return result
}

//
// NOTE: The overrides (`config --overrides`) are the running values that differ from the last applied document. A reload
// puts the file's values back, so an override lasts until the next reload or restart. The file's value of an option is the
// one the applied document lowers to, or the default of the option when the file does not set it (and the defaults are the
// file's values when no document was applied). A per-space value is compared when the file names it for that space or the
// space has an override of it; the space is listed by its Mission Control index.
//

/// The words that a document's entries set: each global option by name, and each per-space option by its Mission Control
/// index. Those are the values the file gives; an option that the file does not set has none here.
func appliedWords(_ entries: [ConfigEntry])
  -> (options: [ConfigName: String], spaces: [Int: [ConfigName: String]])
{
  var fileWords: [ConfigName: String] = [:]
  var spaceWords: [Int: [ConfigName: String]] = [:]
  for entry in entries {
    switch entry.target {
    case .option(let name): fileWords[name] = entry.value
    case .spaceOption(let index, let name): spaceWords[index, default: [:]][name] = entry.value
    case .spaceLabel, .spacePin, .rule, .signal: break
    }
  }
  return (fileWords, spaceWords)
}

/// The lines of `config --overrides`: one per overridden option (`<option> <running> (file: <value>)`), one per overridden
/// per-space option (`space <index> <option> <running> (file: <value>)`), then `rules: overridden` and `signals: overridden`
/// when their lists differ. Nothing changes; no line when nothing is overridden.
@WM func configOverrideLines() -> [String] {
  let defaults = ConfigLoader.shared.defaultWords()
  let entries = ConfigLoader.shared.applied?.lowered() ?? []
  let (fileWords, spaceWords) = appliedWords(entries)

  var lines: [String] = []
  for name in ConfigName.allCases {
    guard let running = printedConfigValue(["config", name.rawValue]),
      let word = fileWords[name] ?? defaults[name],
      !sameConfigValue(name, printed: running, word: word)
    else { continue }
    lines.append("\(name.rawValue) \(running) (file: \(word))")
  }

  // NOTE: The options to compare for each space: those the file names for it, and those a view has an override of.
  var perSpace: [Int: Set<ConfigName>] = [:]
  for (index, words) in spaceWords {
    perSpace[index, default: []].formUnion(words.keys)
  }
  for (sid, view) in SpaceManager.shared.views where !view.overrides.isEmpty {
    guard let index = sid.missionControlIndex else { continue }
    for name in ConfigName.allCases {
      if let override = spaceOverride(name), view.overrides.contains(override) {
        perSpace[index, default: []].insert(name)
      }
    }
  }
  for index in perSpace.keys.sorted() {
    for name in ConfigName.allCases where perSpace[index]?.contains(name) == true {
      guard let running = printedConfigValue(["config", "--space", "\(index)", name.rawValue]),
        let word = spaceWords[index]?[name] ?? fileWords[name] ?? defaults[name],
        !sameConfigValue(name, printed: running, word: word)
      else { continue }
      lines.append("space \(index) \(name.rawValue) \(running) (file: \(word))")
    }
  }

  let fileRules = parsedRules(entries.filter { $0.target == .rule }) ?? []
  if !rulesMatchFile(fileRules, applied: ConfigLoader.shared.applied) {
    lines.append("rules: overridden")
  }
  let fileSignals = parsedSignals(entries.filter { $0.target == .signal }) ?? SignalTable()
  if fileSignals != EventSignals.shared.table {
    lines.append("signals: overridden")
  }
  return lines
}
