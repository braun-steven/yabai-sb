/// A command of the display domain. The daemon resolves selectors when the command runs.
public enum DisplayCommand: Equatable, Sendable {
  case focus(DisplaySelector)
  case space(SpaceSelector)
  case label(Token)

  public enum Name: String, CaseIterable, Sendable {
    case focus = "--focus"
    case space = "--space"
    case label = "--label"
  }

  public static func parse(_ name: Name, _ message: inout Message) throws(CommandError)
    -> DisplayCommand
  {
    let value = message.next()
    switch name {
    case .focus: return .focus(try DisplaySelector.required(value))
    case .space: return .space(try SpaceSelector.required(value))
    case .label: return .label(value)
    }
  }
}
