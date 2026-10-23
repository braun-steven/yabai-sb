import Foundation
import SortedCollections
import YabaiCore

//
// NOTE: `config --dump` prints the running config as a yabai.toml (runningConfigDump, ConfigDocument.toml). Each value is
// the option's own print, read back by its kind (ConfigOptionKind), so the file gives the values a reconcile compares
// with: the dump checks clean, and a reconcile of it runs nothing that the running state does not already differ in. The
// per-space values, the labels and the pins are read by Mission Control index, which reads the window server, so they
// are only written for the spaces that have one. The rules and signals are written from their stored values.
//
// The comments mark the options whose value is not the one the file gives (`# override`, the same test as
// configOverrideLines) and the ones that have the built-in default (`# default`).
//

/// The value of an option from its printed text, by its kind; nil when the text does not read as that kind.
@WM private func dumpValue(_ printed: String, kind: ConfigOptionKind) -> ConfigValue? {
  switch kind {
  case .bool:
    if printed == Argument.on { return .bool(true) }
    if printed == Argument.off { return .bool(false) }
    return nil
  case .integer:
    return Int(printed).map { ConfigValue.integer($0) }
  case .color:
    guard printed.hasPrefix("0x"), let value = UInt32(printed.dropFirst(2), radix: 16) else {
      return nil
    }
    return .integer(Int(value))
  case .float:
    return Double(printed).map { ConfigValue.float($0) }
  case .text:
    return .string(printed)
  case .strings:
    if printed == Argument.off { return .strings([]) }
    return .strings(printed.split(separator: " ").map(String.init))
  }
}

/// The comment of an option line: `override` when the running word is not the one the file gives (`expected`), else
/// `default` when it is the built-in default.
private func dumpComment(printed: String, expected: String?, builtIn: String?) -> String? {
  if let expected, !sameConfigValue(printed, expected) { return "override" }
  if let builtIn, sameConfigValue(printed, builtIn) { return "default" }
  return nil
}

/// The running config as a document, and the comments of its option lines by key path (ConfigDocument.toml).
@WM func runningConfigDump() -> (document: ConfigDocument, comments: [String: String]) {
  let loader = ConfigLoader.shared
  let builtIn = loader.defaultWords()
  let (fileWords, spaceWords) = appliedWords(loader.applied?.lowered() ?? [])

  var document = ConfigDocument()
  document.daemon.autoReload = loader.autoReload
  document.daemon.loadScriptingAddition = loader.loadScriptingAddition
  var comments: [String: String] = [:]

  var options: [ConfigOptionEntry] = []
  for option in configOptions {
    let name = option.name
    guard let printed = printedConfigValue(["config", name.rawValue]),
      let value = dumpValue(printed, kind: option.kind)
    else { continue }
    let keyPath = "config.\(name.rawValue)"
    // NOTE: The disabled mode of focus_follows_mouse prints as `disabled`, which the option does not take; it is written
    // as `off`, which the option takes, and sameConfigValue compares the two as equal.
    if name == .focusFollowsMouse, printed == FocusFollowsMouse.disabled.rawValue {
      options.append(ConfigOptionEntry(name: name, value: .string(Argument.off), keyPath: keyPath))
    } else {
      options.append(ConfigOptionEntry(name: name, value: value, keyPath: keyPath))
    }
    comments[keyPath] = dumpComment(
      printed: printed, expected: fileWords[name] ?? builtIn[name], builtIn: builtIn[name])
  }
  // NOTE: TOML lists the arrays of a table after its plain values, and the decoder keeps that order.
  document.options = options.filter { !$0.value.isList } + options.filter { $0.value.isList }

  let manager = SpaceManager.shared
  for sid in SpaceID.all {
    guard let index = sid.missionControlIndex else { continue }
    let path = "space[\(document.spaces.count)]"

    let label = manager.labels.name(of: sid)
    let pin = label.flatMap { manager.pins.display(of: $0) }.flatMap { uuid -> String? in
      guard let position = DisplayManager.shared.arrangedDisplays?.firstIndex(of: uuid) else {
        return nil
      }
      return String(position + 1)
    }

    let view = manager.views[sid]
    var scoped: [ConfigOptionEntry] = []
    for option in configOptions where ConfigName.spaceScoped.contains(option.name) {
      let name = option.name
      guard let override = spaceOverride(name), view?.overrides.contains(override) == true,
        let printed = printedConfigValue(["config", "--space", "\(index)", name.rawValue]),
        let value = dumpValue(printed, kind: option.kind)
      else { continue }
      let keyPath = "\(path).\(name.rawValue)"
      scoped.append(ConfigOptionEntry(name: name, value: value, keyPath: keyPath))
      comments[keyPath] = dumpComment(
        printed: printed, expected: spaceWords[index]?[name] ?? fileWords[name] ?? builtIn[name],
        builtIn: builtIn[name])
    }

    guard label != nil || pin != nil || !scoped.isEmpty else { continue }
    document.spaces.append(
      SpaceEntry(index: index, label: label, pin: pin, options: scoped, keyPath: path))
  }

  document.rules = WindowManager.shared.rules.enumerated().map { position, rule in
    ruleEntry(rule, path: "rule[\(position)]")
  }

  var signals: [SignalEntry] = []
  let table = EventSignals.shared.table
  for type in SignalType.allCases {
    for signal in table.subscribers(type) {
      guard let command = signal.command else { continue }
      let path = "signal[\(signals.count)]"
      var keys = [
        ConfigKey(
          name: "event", negated: false, value: .string(type.name), keyPath: "\(path).event"),
        ConfigKey(
          name: "action", negated: false, value: .string(command), keyPath: "\(path).action"),
      ]
      if let label = signal.label {
        keys.append(
          ConfigKey(name: "label", negated: false, value: .string(label), keyPath: "\(path).label"))
      }
      if let active = signal.active {
        keys.append(
          ConfigKey(name: "active", negated: false, value: .bool(active), keyPath: "\(path).active")
        )
      }
      for (name, pattern) in [("app", signal.app), ("title", signal.title)] {
        guard let pattern else { continue }
        keys.append(
          ConfigKey(
            name: name, negated: pattern.exclude, value: .string(pattern.text),
            keyPath: "\(path).\(name)"))
      }
      signals.append(SignalEntry(keys: negatedLast(keys), keyPath: path))
    }
  }
  document.signals = signals

  return (document, comments)
}

/// The keys of a rule or signal in the order the decoder gives them: the plain values, then the exclusions.
private func negatedLast(_ keys: [ConfigKey]) -> [ConfigKey] {
  keys.filter { !$0.negated } + keys.filter { $0.negated }
}

/// The `[[rule]]` table of a rule, with the keys that `rule --add` would take to make it. A display or space written
/// with `^` makes the window's space follow it (the follow flag). A display or space index that the window server does
/// not arrange is left out.
@WM private func ruleEntry(_ rule: Rule, path: String) -> RuleEntry {
  var keys: [ConfigKey] = []
  func add(_ name: String, _ value: ConfigValue) {
    keys.append(ConfigKey(name: name, negated: false, value: value, keyPath: "\(path).\(name)"))
  }
  func addPattern(_ name: String, _ pattern: RulePattern?) {
    guard let pattern else { return }
    keys.append(
      ConfigKey(
        name: name, negated: pattern.exclude, value: .string(pattern.text),
        keyPath: "\(path).\(name)"))
  }
  func addBool(_ name: String, _ value: Bool?) {
    if let value { add(name, .bool(value)) }
  }

  let effects = rule.effects
  let follow = effects.flags.contains(.followSpace)
  func selector(_ index: Int) -> ConfigValue {
    follow ? .string("^\(index)") : .integer(index)
  }

  if let label = rule.label { add("label", .string(label)) }
  addPattern("app", rule.app)
  addPattern("title", rule.title)
  addPattern("role", rule.role)
  addPattern("subrole", rule.subrole)
  if let index = effects.did?.arrangement { add("display", selector(index)) }
  if let index = effects.sid?.missionControlIndex { add("space", selector(index)) }
  if let insert = effects.insert { add("insert", .string(insert.argument)) }
  if effects.grid != Grid() {
    let grid = effects.grid
    let text = [grid.rows, grid.columns, grid.x, grid.y, grid.width, grid.height].map {
      String(Int32(bitPattern: $0))
    }.joined(separator: ":")
    add("grid", .string(text))
  }
  if effects.flags.contains(.opacity) {
    // NOTE: The shortest text of the Float, so that the file reads back the same Float.
    add("opacity", .float(Double(String(effects.opacity)) ?? Double(effects.opacity)))
  }
  addBool("manage", effects.manage)
  addBool("sticky", effects.sticky)
  addBool("mouse_follows_focus", effects.mouseFollowsFocus)
  addBool("native-fullscreen", effects.fullscreen)
  if effects.flags.contains(.layer) { add("sub-layer", .string(effects.layer.rawValue)) }
  if let scratchpad = effects.scratchpad { add("scratchpad", .string(scratchpad)) }

  return RuleEntry(keys: negatedLast(keys), oneShot: rule.oneShot, keyPath: path)
}

/// Writes `config --dump`: the running config as yabai.toml text.
@WM func handleConfigDump(_ rsp: inout Response, _ message: inout Message) throws(CommandError) {
  try noConfigArgument("--dump", &message)
  let dump = runningConfigDump()
  rsp.write(ResponseText(stringLiteral: dump.document.toml(comments: dump.comments)))
}
