/// A selector accepted by `rule --apply` and `rule --remove`.
public enum RuleSelector {
  case index(Int)
  case label(Token)
}

/// The parsed value of a `rule --apply` command.
public enum RuleApply {
  case all
  case index(Int)
  /// Apply a rule whose label was not found. The inline parse error is kept until execution so an existing label
  /// continues to take precedence over tokens that could otherwise be invalid rule fields.
  case labelOrInline(Token, Result<Rule?, CommandError>)
}

/// A command of the rule domain, parsed into its operation and payload.
public enum RuleCommand {
  case add(Rule)
  case apply(RuleApply)
  case remove(RuleSelector)
  case list
  case ignore

  private enum Name: String, CaseIterable {
    case add = "--add"
    case remove = "--remove"
    case apply = "--apply"
    case list = "--list"
    case oneShot = "--one-shot"
  }

  /// Parses one rule command. Display and space effects keep the behavior of `parseRule`, including its current
  /// selector resolution against the supplied context.
  public static func parse<C: SelectorContext>(_ message: inout some TokenSource, _ context: C)
    throws(CommandError) -> RuleCommand
  {
    let command = message.next()
    guard let name = Name(token: command) else {
      throw CommandError.unknownCommand(Token(Domain.rule), command)
    }

    switch name {
    case .add:
      var rule = Rule()
      var first = message.next()
      if Name(token: first) == .oneShot {
        rule.oneShot = true
        first = message.next()
      }
      return try parseRule(&message, &rule, first, context) ? .add(rule) : .ignore

    case .apply:
      let selector = message.next()
      switch selector.value {
      case .int(let index):
        return .apply(.index(Int(index)))
      case .string:
        var rule = Rule()
        do {
          let parsed = try parseRule(&message, &rule, selector, context)
          return .apply(.labelOrInline(selector, .success(parsed ? rule : nil)))
        } catch {
          return .apply(.labelOrInline(selector, .failure(error)))
        }
      case .invalid:
        return .apply(.all)
      default:
        throw CommandError("value '\(selector)' is not a valid option for RULE_SEL\n")
      }

    case .remove:
      let selector = message.next()
      switch selector.value {
      case .int(let index): return .remove(.index(Int(index)))
      case .string: return .remove(.label(selector))
      default: throw CommandError("value '\(selector)' is not a valid option for RULE_SEL\n")
      }

    case .list:
      return .list
    case .oneShot:
      throw CommandError.unknownCommand(Token(Domain.rule), command)
    }
  }
}
