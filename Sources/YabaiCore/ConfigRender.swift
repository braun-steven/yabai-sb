//
// NOTE: ConfigDocument.toml() writes a document as yabai.toml text, the form that ConfigDocument.decode reads back. The
// keys of a table are written in the order that decoding gives them: the plain values first, then the arrays, then the
// inline tables (`{ not = … }`), which is the order `TOMLTable.keys` lists them in. A document in that order decodes to
// the same document (`decode(toml()) == self`); the options and the rule and signal keys of ConfigDocument are kept in
// that order by the decoder, and the renderer puts any other document in it too.
//

extension ConfigDocument {
  /// The document as `yabai.toml` text. `comments` maps the key path of an option (`config.window_gap`,
  /// `space[0].window_gap`) to a comment written after its line, e.g. `default` gives `# default`.
  public func toml(comments: [String: String] = [:]) -> String {
    var sections: [String] = []

    sections.append(
      section(
        "[daemon]",
        lines: [
          "auto_reload = \(daemon.autoReload)",
          "load_scripting_addition = \(daemon.loadScriptingAddition)",
        ]))

    sections.append(
      section(
        "[config]",
        lines: plainFirst(options, isList: \.value.isList).map { option in
          optionLine(option, comments: comments)
        }))

    for space in spaces {
      var lines: [String] = ["index = \(space.index)"]
      if let label = space.label { lines.append("label = \(quoted(label))") }
      if let pin = space.pin { lines.append("pin = \(quoted(pin))") }
      lines += plainFirst(space.options, isList: \.value.isList).map { option in
        optionLine(option, comments: comments)
      }
      sections.append(section("[[space]]", lines: lines))
    }

    for rule in rules {
      var lines = plainFirst(rule.keys, isList: \.negated).map(keyLine)
      if rule.oneShot { lines.append("one_shot = true") }
      sections.append(section("[[rule]]", lines: lines))
    }

    for signal in signals {
      sections.append(
        section("[[signal]]", lines: plainFirst(signal.keys, isList: \.negated).map(keyLine)))
    }

    return sections.joined(separator: "\n\n") + "\n"
  }
}

private func section(_ header: String, lines: [String]) -> String {
  ([header] + lines).joined(separator: "\n")
}

/// The elements that do not match `isList`, then the ones that do, each in their order.
private func plainFirst<Element>(_ elements: [Element], isList: (Element) -> Bool) -> [Element] {
  elements.filter { !isList($0) } + elements.filter(isList)
}

/// One option line. An integer named `*_color` is written as the hex color it is (`0xff51afef`), as the file gives it.
private func optionLine(_ option: ConfigOptionEntry, comments: [String: String]) -> String {
  let name = option.name.rawValue
  var value = tomlValue(option.value)
  if case .integer(let number) = option.value, name.hasSuffix("_color"),
    (0...Int(UInt32.max)).contains(number)
  {
    value = "0x" + hexDigits(UInt32(number))
  }
  var line = "\(name) = \(value)"
  if let comment = comments[option.keyPath] { line += " # \(comment)" }
  return line
}

/// One key of a rule or signal. An exclusion is `key = { not = "value" }`.
private func keyLine(_ key: ConfigKey) -> String {
  let value = tomlValue(key.value)
  if key.negated {
    return "\(key.name) = { not = \(value) }"
  }
  return "\(key.name) = \(value)"
}

private func tomlValue(_ value: ConfigValue) -> String {
  switch value {
  case .bool(let enabled):
    return enabled ? "true" : "false"
  case .integer(let number):
    return String(number)
  case .float(let number):
    return floatText(number)
  case .string(let text):
    return quoted(text)
  case .strings(let texts):
    return "[" + texts.map(quoted).joined(separator: ", ") + "]"
  }
}

/// A TOML float: `nan` and `inf` are TOML's own spellings; Swift's shortest form is otherwise valid TOML (`3.0`, `1e+16`).
private func floatText(_ number: Double) -> String {
  if number.isNaN { return "nan" }
  if number.isInfinite { return number < 0 ? "-inf" : "inf" }
  return String(number)
}

/// A basic string with the escapes TOML needs: the quote, the backslash and the control characters.
private func quoted(_ text: String) -> String {
  var result = "\""
  for scalar in text.unicodeScalars {
    switch scalar {
    case "\"": result += "\\\""
    case "\\": result += "\\\\"
    case "\n": result += "\\n"
    case "\t": result += "\\t"
    case "\r": result += "\\r"
    case _ where scalar.value < 0x20 || scalar.value == 0x7F:
      result +=
        "\\u" + String(repeating: "0", count: 4 - String(scalar.value, radix: 16).count)
        + String(scalar.value, radix: 16, uppercase: true)
    default:
      result.unicodeScalars.append(scalar)
    }
  }
  return result + "\""
}

/// Eight lowercase hex digits.
private func hexDigits(_ value: UInt32) -> String {
  let digits = String(value, radix: 16)
  return String(repeating: "0", count: 8 - digits.count) + digits
}

extension ConfigValue {
  /// Whether the value is an array, which TOML writes after the plain values of its table.
  public var isList: Bool {
    if case .strings = self { return true }
    return false
  }
}
