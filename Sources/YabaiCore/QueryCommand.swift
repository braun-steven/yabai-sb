/// A command of the query domain. Selectors remain unresolved until the daemon runs the command.
public enum QueryCommand: Equatable, Sendable {
  public enum Target: Equatable, Sendable {
    case all
    case display(DisplaySelector?)
    case space(SpaceSelector?)
    case window(WindowSelector?)
  }

  case displays(properties: Set<DisplayInfo.Key>, target: Target)
  case spaces(properties: Set<SpaceInfo.Key>, target: Target)
  case windows(properties: Set<WindowInfo.Key>, target: Target)
  case tree(space: SpaceSelector?)

  private enum Name: String, CaseIterable, Equatable {
    case displays = "--displays"
    case spaces = "--spaces"
    case windows = "--windows"
    case tree = "--tree"
  }

  private enum TargetOption: String, CaseIterable {
    case display = "--display"
    case space = "--space"
    case window = "--window"
  }

  /// Parses one query command from the message.
  public static func parse(_ message: inout some TokenSource) throws(CommandError) -> QueryCommand {
    let nameToken = message.next()
    guard let name = Name(token: nameToken) else {
      throw CommandError.unknownCommand(Token(Domain.query), nameToken)
    }

    switch name {
    case .displays:
      let (properties, target) = try parseSelection(DisplayInfo.Key.self, nameToken, &message)
      return .displays(properties: properties, target: target)
    case .spaces:
      let (properties, target) = try parseSelection(SpaceInfo.Key.self, nameToken, &message)
      return .spaces(properties: properties, target: target)
    case .windows:
      let (properties, target) = try parseSelection(WindowInfo.Key.self, nameToken, &message)
      return .windows(properties: properties, target: target)
    case .tree:
      let option = message.next()
      if option.equals(TargetOption.space.rawValue) {
        return .tree(space: try optionalSpaceSelector(message.next()))
      }
      if option.isValid { throw CommandError.unknownOption(Token(Domain.query), nameToken, option) }
      return .tree(space: nil)
    }
  }

  private static func parseSelection<
    Key: CaseIterable & RawRepresentable<String> & Hashable & Sendable
  >(_ key: Key.Type, _ command: Token, _ message: inout some TokenSource) throws(CommandError) -> (
    Set<Key>, Target
  ) {
    let properties = try parseProperties(message.next(), as: Key.self)
    let optionToken = properties.didParse ? message.next() : properties.token
    return (properties.selection, try parseTarget(optionToken, command, &message))
  }

  private static func parseTarget(
    _ optionToken: Token, _ command: Token, _ message: inout some TokenSource
  ) throws(CommandError) -> Target {
    guard let option = TargetOption(token: optionToken) else {
      if optionToken.isValid {
        throw CommandError.unknownOption(Token(Domain.query), command, optionToken)
      }
      return .all
    }

    let selector = message.next()
    switch option {
    case .display: return .display(try optionalDisplaySelector(selector))
    case .space: return .space(try optionalSpaceSelector(selector))
    case .window: return .window(try optionalWindowSelector(selector))
    }
  }

  private static func optionalDisplaySelector(_ token: Token) throws(CommandError)
    -> DisplaySelector?
  {
    guard token.isValid else { return nil }
    return try DisplaySelector.required(token)
  }

  private static func optionalSpaceSelector(_ token: Token) throws(CommandError) -> SpaceSelector? {
    guard token.isValid else { return nil }
    return try SpaceSelector.required(token)
  }

  private static func optionalWindowSelector(_ token: Token) throws(CommandError) -> WindowSelector?
  {
    guard token.isValid else { return nil }
    return try WindowSelector.required(token)
  }
}
