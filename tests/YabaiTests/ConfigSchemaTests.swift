import Foundation
import Testing
import YabaiCore

@testable import Yabai

// NOTE: The schema is checked against the names and the choices that the decoder and the handlers use. The choice types
// are in the Yabai target, so the test is in YabaiTests. The file is read through a path relative to this file.

/// The schema, as a JSON object.
private func loadSchema() throws -> [String: Any] {
  let url = URL(filePath: #filePath)
    .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    .appending(path: "doc/yabai.schema.json")
  let data = try Data(contentsOf: url)
  return try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
}

/// The properties of an object schema.
private func properties(_ object: [String: Any]) -> [String: [String: Any]] {
  (object["properties"] as? [String: Any] ?? [:]).compactMapValues { $0 as? [String: Any] }
}

/// The schema of the items of an array schema.
private func items(_ array: [String: Any]) -> [String: Any] {
  array["items"] as? [String: Any] ?? [:]
}

/// The `enum` of a property: its own, or the one of a branch of `anyOf`.
private func enumValues(_ property: [String: Any]) -> [String]? {
  if let values = property["enum"] as? [String] { return values }
  let branches = property["anyOf"] as? [[String: Any]] ?? []
  return branches.lazy.compactMap { $0["enum"] as? [String] }.first
}

/// Whether a property takes `{ not = … }`: one of its branches is an object with the required key `not`.
private func takesNegation(_ property: [String: Any]) -> Bool {
  let branches = property["anyOf"] as? [[String: Any]] ?? []
  return branches.contains { ($0["required"] as? [String]) == ["not"] }
}

/// A row of expected choices: the option, and the raw values of the choice type it is parsed with.
struct ChoiceRow: Sendable, CustomTestStringConvertible {
  let option: String
  let expected: [String]
  var testDescription: String { option }
}

private let configChoices: [ChoiceRow] = [
  ChoiceRow(
    option: "display_arrangement_order", expected: DisplayArrangementOrder.allCases.map(\.rawValue)),
  ChoiceRow(option: "window_origin_display", expected: WindowOrigin.allCases.map(\.rawValue)),
  ChoiceRow(option: "window_shadow", expected: PurifyMode.allCases.map(\.rawValue)),
  ChoiceRow(option: "tree_default_orientation", expected: TreeOrientation.allCases.map(\.rawValue)),
  ChoiceRow(option: "tree_workspace_layout", expected: WorkspaceLayout.allCases.map(\.rawValue)),
  ChoiceRow(option: "focus_wrapping", expected: FocusWrapping.allCases.map(\.rawValue)),
  ChoiceRow(option: "mouse_modifier", expected: MouseModifierKey.allCases.map(\.rawValue)),
  ChoiceRow(option: "mouse_action1", expected: [MouseAction.move, .resize].map(\.rawValue)),
  ChoiceRow(option: "mouse_action2", expected: [MouseAction.move, .resize].map(\.rawValue)),
  ChoiceRow(option: "mouse_drop_action", expected: [MouseAction.swap, .stack].map(\.rawValue)),
  ChoiceRow(option: "tab_bar_appearance", expected: TabBarAppearance.allCases.map(\.rawValue)),
  ChoiceRow(option: "tab_bar_backdrop", expected: TabBarBackdrop.allCases.map(\.rawValue)),
  // NOTE: `focus_follows_mouse` takes `off` for the disabled mode, whose raw value is `disabled`.
  ChoiceRow(
    option: "focus_follows_mouse",
    expected: ["off"] + [FocusFollowsMouse.autofocus, .autoraise].map(\.rawValue)),
  ChoiceRow(option: "layout", expected: [ViewType.float, .tree].map(\.rawValue)),
]

@Test func configPropertiesAreTheOptionNames() throws {
  let config = try #require(properties(try loadSchema())["config"])
  let names = Set(ConfigCommand.Name.allCases.map(\.rawValue))
  let schemaNames = Set(properties(config).keys)
  #expect(
    schemaNames == names,
    "options without a schema entry or extra: \(schemaNames.symmetricDifference(names).sorted())")
  for (name, property) in properties(config) {
    let description = property["description"] as? String ?? ""
    #expect(!description.isEmpty, "\(name) has no description")
  }
}

@Test func spacePropertiesAreTheSpaceKeys() throws {
  let space = try #require(properties(try loadSchema())["space"])
  let keys = Set(properties(items(space)).keys)
  let expected = Set(["index", "label", "pin"]).union(
    ConfigCommand.Name.spaceScoped.map(\.rawValue))
  #expect(
    keys == expected, "space keys: \(keys.symmetricDifference(expected).sorted())")
  #expect(items(space)["required"] as? [String] == ["index"])
}

@Test func ruleAndSignalPropertiesAreTheDecoderKeys() throws {
  let schema = try loadSchema()
  let top = properties(schema)

  let rule = properties(items(try #require(top["rule"])))
  let ruleKeys = Set(rule.keys).subtracting(["one_shot"])
  #expect(
    ruleKeys == ConfigTableKeys.rule,
    "rule keys: \(ruleKeys.symmetricDifference(ConfigTableKeys.rule).sorted())")
  #expect(rule["one_shot"]?["type"] as? String == "boolean")
  let ruleNegatable = Set(rule.filter { takesNegation($0.value) }.keys)
  #expect(ruleNegatable == ConfigTableKeys.ruleNegatable)

  let signalTable = try #require(top["signal"])
  let signal = properties(items(signalTable))
  #expect(
    Set(signal.keys) == ConfigTableKeys.signal,
    "signal keys: \(Set(signal.keys).symmetricDifference(ConfigTableKeys.signal).sorted())")
  let signalNegatable = Set(signal.filter { takesNegation($0.value) }.keys)
  #expect(signalNegatable == ConfigTableKeys.signalNegatable)
  #expect((items(signalTable)["required"] as? [String])?.sorted() == ["action", "event"])
}

@Test func topLevelAndDaemonKeys() throws {
  let top = try loadSchema()
  #expect(Set(properties(top).keys) == ConfigTableKeys.topLevel)
  let daemon = try #require(properties(top)["daemon"])
  // NOTE: The keys of [daemon] are the cases of DaemonSettings in the decoder (ConfigDocumentDecoding.swift).
  #expect(Set(properties(daemon).keys) == ["auto_reload", "load_scripting_addition"])
}

@Test(arguments: configChoices)
func choiceOptionsListTheRawValuesOfTheirChoiceType(row: ChoiceRow) throws {
  let config = try #require(properties(try loadSchema())["config"])
  let property = try #require(properties(config)[row.option])
  #expect(enumValues(property) == row.expected)
}

@Test func spaceLayoutChoiceListsTheRawValues() throws {
  let space = try #require(properties(try loadSchema())["space"])
  let property = try #require(properties(items(space))["layout"])
  #expect(enumValues(property) == [ViewType.float, .tree].map(\.rawValue))
}

@Test func ruleSubLayerListsTheWindowLayers() throws {
  let rule = try #require(properties(try loadSchema())["rule"])
  let property = try #require(properties(items(rule))["sub-layer"])
  #expect(enumValues(property) == WindowLayer.allCases.map(\.rawValue))
}

@Test func signalEventListsTheSignalTypes() throws {
  let signal = try #require(properties(try loadSchema())["signal"])
  let property = try #require(properties(items(signal))["event"])
  #expect(enumValues(property) == SignalType.allCases.map(\.name))
}
