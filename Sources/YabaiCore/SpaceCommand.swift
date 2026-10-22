import Darwin

/// A command of the space domain. Selectors are parsed here and resolved by the daemon when the command runs.
public enum SpaceCommand: Equatable, Sendable {
  case focus(SpaceSelector)
  case `switch`(SpaceSelector)
  case create(DisplaySelector?)
  case destroy(SpaceSelector?)
  case move(SpaceSelector)
  case swap(SpaceSelector)
  case display(DisplaySelector)
  case equalize(SpaceCommandAxis?)
  case balance(SpaceCommandAxis?)
  case mirror(SpaceCommandAxis)
  case rotate(Int)
  case padding(ValueType?, top: Int, bottom: Int, left: Int, right: Int)
  case gap(ValueType?, Int)
  case toggle(SpaceToggle)
  case layout(SpaceCommandLayout)
  case label(Token)

  public enum Name: String, CaseIterable, Sendable {
    case focus = "--focus"
    case `switch` = "--switch"
    case create = "--create"
    case destroy = "--destroy"
    case move = "--move"
    case swap = "--swap"
    case display = "--display"
    case equalize = "--equalize"
    case balance = "--balance"
    case mirror = "--mirror"
    case rotate = "--rotate"
    case padding = "--padding"
    case gap = "--gap"
    case toggle = "--toggle"
    case layout = "--layout"
    case label = "--label"

    /// Layout and appearance commands fail before parsing a value when the acting space is missing.
    public var needsActingSpace: Bool {
      switch self {
      case .equalize, .balance, .mirror, .rotate, .padding, .gap, .toggle, .layout, .label: true
      default: false
      }
    }
  }

  /// The failure of a command given a value it does not accept; `expected` names the values it takes.
  public static func unknownValue(_ name: Name, _ value: Token, expected: String) -> CommandError {
    CommandError.unknownValue(Token(Domain.space), Token(name.rawValue), value, expected: expected)
  }

  public static func parse(_ name: Name, _ message: inout some TokenSource) throws(CommandError)
    -> SpaceCommand
  {
    let value = message.next()
    switch name {
    case .focus: return .focus(try SpaceSelector.required(value))
    case .switch: return .switch(try SpaceSelector.required(value))
    case .create: return .create(try optionalDisplay(value))
    case .destroy: return .destroy(try optionalSpace(value))
    case .move: return .move(try SpaceSelector.required(value))
    case .swap: return .swap(try SpaceSelector.required(value))
    case .display: return .display(try DisplaySelector.required(value))
    case .equalize: return .equalize(try optionalAxis(value, name))
    case .balance: return .balance(try optionalAxis(value, name))
    case .mirror:
      guard let axis = SpaceCommandAxis(token: value) else {
        throw unknownValue(name, value, expected: axisChoices)
      }
      return .mirror(axis)
    case .rotate:
      let degrees =
        value.equals("90") ? 90 : value.equals("180") ? 180 : value.equals("270") ? 270 : 0
      guard degrees != 0 else { throw unknownValue(name, value, expected: "one of: 90, 180, 270") }
      return .rotate(degrees)
    case .padding:
      let scan = value.scanIntegers(field: 255, count: 4)
      guard scan.assigned == 5, let type = scan.field else {
        throw unknownValue(
          name, value,
          expected: "abs or rel, then four integers as top:bottom:left:right, e.g. abs:10:10:10:10")
      }
      return .padding(
        parseValueType(type), top: Int(scan.values[0]), bottom: Int(scan.values[1]),
        left: Int(scan.values[2]), right: Int(scan.values[3]))
    case .gap:
      let scan = value.scanIntegers(field: 255, count: 1)
      guard scan.assigned == 2, let type = scan.field else {
        throw unknownValue(name, value, expected: "abs or rel, then one integer, e.g. abs:10")
      }
      return .gap(parseValueType(type), Int(scan.values[0]))
    case .toggle:
      guard let toggle = SpaceToggle(token: value) else {
        throw unknownValue(
          name, value, expected: expectedChoices(SpaceToggle.allCases.map(\.rawValue)))
      }
      return .toggle(toggle)
    case .layout:
      guard let layout = SpaceCommandLayout(token: value) else {
        throw unknownValue(
          name, value, expected: expectedChoices(SpaceCommandLayout.allCases.map(\.rawValue)))
      }
      return .layout(layout)
    case .label: return .label(value)
    }
  }

  private static func optionalDisplay(_ token: Token) throws(CommandError) -> DisplaySelector? {
    guard token.isValid else { return nil }
    do { return try DisplaySelector.required(token) } catch { throw error.stoppingMessage }
  }

  private static func optionalSpace(_ token: Token) throws(CommandError) -> SpaceSelector? {
    guard token.isValid else { return nil }
    do { return try SpaceSelector.required(token) } catch { throw error.stoppingMessage }
  }

  private static func optionalAxis(_ token: Token, _ name: Name) throws(CommandError)
    -> SpaceCommandAxis?
  {
    guard token.isValid else { return nil }
    guard let axis = SpaceCommandAxis(token: token) else {
      throw unknownValue(name, token, expected: axisChoices)
    }
    return axis
  }

  private static let axisChoices = expectedChoices(SpaceCommandAxis.allCases.map(\.rawValue))
}

public enum SpaceCommandAxis: String, CaseIterable, Sendable {
  case xAxis = "x-axis"
  case yAxis = "y-axis"
}

public enum SpaceToggle: String, CaseIterable, Sendable {
  case padding, gap
  case missionControl = "mission-control"
  case showDesktop = "show-desktop"
}

public enum SpaceCommandLayout: String, CaseIterable, Sendable {
  case float, tree
}
