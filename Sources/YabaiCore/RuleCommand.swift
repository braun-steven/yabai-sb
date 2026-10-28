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
  public static func parse<C: SelectorContext>(_ message: inout Message, _ context: C)
    throws(CommandError) -> RuleCommand
  {
    let command = message.next()
    guard let name = Name(token: command) else {
      throw CommandError.unknownCommand(Token(Domain.rule), command)
    }

    switch name {
    case .add:
      var rule = Rule()
      var first = message.take()
      if let token = first, Name(token: token) == .oneShot {
        rule.oneShot = true
        first = message.take()
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

/// Parses "on" or "off" into prop; false for any other value, which leaves prop as it was.
private func parseRuleProp(_ value: Token, _ prop: inout Bool?) -> Bool {
  if value.equals(Argument.on) {
    prop = true
  } else if value.equals(Argument.off) {
    prop = false
  } else {
    return false
  }

  return true
}

//
// NOTE: A display or space value that starts with '^' also makes the window's space follow (focus) it.
//

/// Strip the optional follow-space prefix.
private func parseRuleFollowPrefix(_ effects: inout RuleEffects, _ value: Token) -> Token {
  guard value.hasPrefix("^") else { return value }

  effects.followSpace = true
  return value.dropFirst(1)
}

//
// NOTE: When a key is given more than once, the last value wins, a pattern with its exclusion.
//

/// Parse the key-value pairs of a rule, from the first token to the end of the message. Report all
/// field problems together when the rule is invalid. Returns false, without a failure, when a display or space
/// selector found nothing ('recent'): the rule is then not used either.
public func parseRule<C: SelectorContext>(
  _ message: inout Message, _ rule: inout Rule, _ first: Token?, _ context: C
) throws(CommandError) -> Bool {
  var scanner = KeyValueScanner(first: first)
  var hasFilter = false

  while let pair = scanner.next(&message) {
    let key = pair.key
    var value = pair.value
    var isFilter = false
    var validValue = true
    var validPattern = true

    if key.equals("label") {
      rule.label = value.string
    } else if key.equals("scratchpad") {
      validValue = !LabelKind.window.isReserved(value)
      if validValue {
        rule.effects.scratchpad = value.string
        rule.effects.manage = false
      }
    } else if key.equals("app") {
      isFilter = true
      rule.app = RulePattern(value, exclude: pair.exclusion)
      validPattern = rule.app?.regex != nil
    } else if key.equals("title") {
      isFilter = true
      rule.title = RulePattern(value, exclude: pair.exclusion)
      validPattern = rule.title?.regex != nil
    } else if key.equals("role") {
      isFilter = true
      rule.role = RulePattern(value, exclude: pair.exclusion)
      validPattern = rule.role?.regex != nil
    } else if key.equals("subrole") {
      isFilter = true
      rule.subrole = RulePattern(value, exclude: pair.exclusion)
      validPattern = rule.subrole?.regex != nil
    } else if key.equals("display") {
      value = parseRuleFollowPrefix(&rule.effects, value)
      if let selector = DisplaySelector(value) {
        do {
          if let did = try selector.resolve(acting: context.activeDisplay, context) {
            rule.effects.did = did
          } else {
            scanner.reject()
          }
        } catch {
          scanner.fail(error)
        }
      } else {
        scanner.fail(DisplaySelector.invalid(value))
      }
    } else if key.equals("space") {
      value = parseRuleFollowPrefix(&rule.effects, value)
      if let selector = SpaceSelector(value) {
        do {
          if let sid = try selector.resolve(acting: context.activeSpace, context) {
            rule.effects.sid = sid
          } else {
            scanner.reject()
          }
        } catch {
          scanner.fail(error)
        }
      } else {
        scanner.fail(SpaceSelector.invalid(value))
      }
    } else if key.equals("insert") {
      // NOTE: the same selector as window --insert: a direction or stack.
      if let insert = try? parseInsertSelector(value) {
        rule.effects.insert = insert
      } else {
        validValue = false
      }
    } else if key.equals("grid") {
      validValue = rule.effects.grid.parse(value)
    } else if key.equals("manage") {
      validValue = parseRuleProp(value, &rule.effects.manage)
    } else if key.equals("sticky") {
      validValue = parseRuleProp(value, &rule.effects.sticky)
    } else if key.equals("mouse_follows_focus") {
      validValue = parseRuleProp(value, &rule.effects.mouseFollowsFocus)
    } else if key.equals("native-fullscreen") {
      validValue = parseRuleProp(value, &rule.effects.fullscreen)
    } else if key.equals("sub-layer") {
      let layer = parseLayer(value)
      validValue = layer != nil
      if let layer {
        rule.effects.layer = layer
      }
    } else {
      scanner.unknownKey(key)
      continue
    }

    hasFilter = hasFilter || isFilter
    scanner.check(pair, filter: isFilter, validValue: validValue, validPattern: validPattern)
  }

  if !hasFilter {
    scanner.fail(CommandError("missing required key-value pair 'app[!]=..' or 'title[!]=..'\n"))
  }
  return try scanner.finish()
}
