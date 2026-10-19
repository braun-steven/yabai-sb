/// A command of the query domain. Selectors remain unresolved until the daemon runs the command.
public enum QueryCommand: Equatable, Sendable
{
    public enum Target: Equatable, Sendable
    {
        case all
        case display(DisplaySelector?)
        case space(SpaceSelector?)
        case window(WindowSelector?)
    }

    case displays(properties: UInt64, target: Target)
    case spaces(properties: UInt64, target: Target)
    case windows(properties: UInt64, target: Target)
    case tree(space: SpaceSelector?)

    private enum Name: String, CaseIterable, Equatable
    {
        case displays = "--displays"
        case spaces = "--spaces"
        case windows = "--windows"
        case tree = "--tree"

        init?(_ token: Token)
        {
            guard let name = Self.allCases.first(where: { token.equals($0.rawValue) }) else { return nil }
            self = name
        }
    }

    private enum TargetOption: String, CaseIterable
    {
        case display = "--display"
        case space = "--space"
        case window = "--window"

        init?(_ token: Token)
        {
            guard let option = Self.allCases.first(where: { token.equals($0.rawValue) }) else { return nil }
            self = option
        }
    }

    /// Parses one query command from the message.
    public static func parse(_ message: inout some TokenSource) throws(CommandError) -> QueryCommand
    {
        let nameToken = message.next()
        guard let name = Name(nameToken) else { throw CommandError.unknownCommand(Token(Domain.query), nameToken) }

        if name == .tree {
            let option = message.next()
            if option.equals(TargetOption.space.rawValue) {
                return .tree(space: try optionalSpaceSelector(message.next()))
            }
            if option.isValid { throw CommandError.unknownOption(Token(Domain.query), nameToken, option) }
            return .tree(space: nil)
        }

        let propertyList: PropertyList
        switch name {
        case .displays: propertyList = DisplayProperty.list
        case .spaces:   propertyList = SpaceProperty.list
        case .windows:  propertyList = WindowProperty.list
        case .tree:     return .tree(space: nil)
        }

        let properties = try parseProperties(message.next(), names: propertyList.map(\.name), values: propertyList.map(\.value))
        let optionToken = properties.didParse ? message.next() : properties.token
        let target = try parseTarget(optionToken, nameToken, &message)

        switch name {
        case .displays: return .displays(properties: properties.flags, target: target)
        case .spaces:   return .spaces(properties: properties.flags, target: target)
        case .windows:  return .windows(properties: properties.flags, target: target)
        case .tree:     return .tree(space: nil)
        }
    }

    private static func parseTarget(_ optionToken: Token, _ command: Token, _ message: inout some TokenSource) throws(CommandError) -> Target
    {
        guard let option = TargetOption(optionToken) else {
            if optionToken.isValid { throw CommandError.unknownOption(Token(Domain.query), command, optionToken) }
            return .all
        }

        let selector = message.next()
        switch option {
        case .display: return .display(try optionalDisplaySelector(selector))
        case .space:   return .space(try optionalSpaceSelector(selector))
        case .window:  return .window(try optionalWindowSelector(selector))
        }
    }

    private static func optionalDisplaySelector(_ token: Token) throws(CommandError) -> DisplaySelector?
    {
        guard token.isValid else { return nil }
        return try DisplaySelector.required(token)
    }

    private static func optionalSpaceSelector(_ token: Token) throws(CommandError) -> SpaceSelector?
    {
        guard token.isValid else { return nil }
        return try SpaceSelector.required(token)
    }

    private static func optionalWindowSelector(_ token: Token) throws(CommandError) -> WindowSelector?
    {
        guard token.isValid else { return nil }
        return try WindowSelector.required(token)
    }
}
