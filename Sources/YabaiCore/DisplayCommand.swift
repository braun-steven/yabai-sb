/// A command of the display domain. The daemon resolves selectors when the command runs.
public enum DisplayCommand: Equatable, Sendable
{
    case focus(DisplaySelector)
    case space(SpaceSelector)
    case label(Token)

    public enum Name: String, CaseIterable, Sendable
    {
        case focus = "--focus", space = "--space", label = "--label"

        public init?(_ token: Token)
        {
            guard let name = Self.allCases.first(where: { token.equals($0.rawValue) }) else { return nil }
            self = name
        }
    }

    public static func parse(_ name: Name, _ message: inout some TokenSource) throws(CommandError) -> DisplayCommand
    {
        let value = message.next()
        switch name {
        case .focus: return .focus(try DisplaySelector.required(value))
        case .space: return .space(try SpaceSelector.required(value))
        case .label: return .label(value)
        }
    }
}
