/// The properties read once for a window's two rule rounds.
public struct RuleMatchContext: Sendable {
  public let app: String
  public let title: String
  public let role: String
  public let subrole: String

  public init(app: String, title: String, role: String, subrole: String) {
    self.app = app
    self.title = title
    self.role = role
    self.subrole = subrole
  }
}

public enum RulePhase {
  case management
  case effects(managedByRule: Bool)
}

public enum RuleLifecycle {
  case newWindow
  case existingWindow
}

/// Ordered rule definitions and their one-shot runtime state. All evaluation is independent of the window server.
public struct RuleSet: RandomAccessCollection, ExpressibleByArrayLiteral {
  private struct Entry {
    var rule: Rule
    var matched = false
  }

  private var entries: [Entry] = []

  public init(_ rules: [Rule] = []) {
    for rule in rules { add(rule) }
  }

  public init(arrayLiteral elements: Rule...) {
    self.init(elements)
  }

  public var startIndex: Int { entries.startIndex }
  public var endIndex: Int { entries.endIndex }
  public subscript(index: Int) -> Rule { entries[index].rule }
  public var definitions: [Rule] { entries.map(\.rule) }
  public var unmatchedOneShotRules: [Rule] {
    entries.filter { $0.rule.oneShot && !$0.matched }.map(\.rule)
  }

  public func hasMatched(at index: Int) -> Bool { entries[index].matched }

  public func index(label: String) -> Int? {
    entries.firstIndex { $0.rule.label == label }
  }

  /// A replacement keeps its precedence and starts with fresh runtime state.
  public mutating func add(_ rule: Rule) {
    let entry = Entry(rule: rule)
    if let label = rule.label, let index = index(label: label) {
      entries[index] = entry
    } else {
      entries.append(entry)
    }
  }

  @discardableResult
  public mutating func remove(at index: Int) -> Bool {
    guard entries.indices.contains(index) else { return false }
    entries.remove(at: index)
    return true
  }

  @discardableResult
  public mutating func remove(label: String) -> Bool {
    guard let index = index(label: label) else { return false }
    return remove(at: index)
  }

  /// Called after a discovery batch, so a one-shot can still match other windows in the same batch.
  public mutating func removeConsumedOneShotRules() {
    entries.removeAll { $0.matched }
  }

  /// Nil means no rule matched; an empty effects value still represents a match.
  public mutating func matchingEffects(
    for context: RuleMatchContext, phase: RulePhase, lifecycle: RuleLifecycle
  ) -> RuleEffects? {
    var effects: RuleEffects?
    for index in entries.indices {
      let rule = entries[index].rule
      if lifecycle == .existingWindow && rule.oneShot { continue }
      guard
        rule.matches(
          app: context.app, title: context.title, role: context.role, subrole: context.subrole
        )
      else { continue }

      let standardOnly: Bool
      switch phase {
      case .management: standardOnly = rule.effects.manage == true
      case .effects(let managedByRule): standardOnly = !managedByRule
      }
      // NOTE: Without explicit role/subrole filters, management opt-in and ordinary effects are restricted
      // to standard windows. A preceding manage rule can admit a window that misreports its role.
      if standardOnly {
        if !rule.hasRole && context.role != "AXWindow" { continue }
        if !rule.hasSubrole && context.subrole != "AXStandardWindow" { continue }
      }

      if effects == nil { effects = RuleEffects() }
      effects?.combine(rule.effects)
      if rule.oneShot { entries[index].matched = true }
    }
    return effects
  }
}
