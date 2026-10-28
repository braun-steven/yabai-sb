/// A regular expression in Swift `Regex` syntax, matched anywhere in the text.
/// Matching uses Unicode characters and supports inline flags and lookaround; it is not POSIX byte matching.
public struct PatternRegex {
  private let regex: Regex<AnyRegexOutput>

  /// Nil when the pattern is not a valid regular expression.
  public init?(_ pattern: String) {
    guard let regex = try? Regex(pattern) else { return nil }
    self.regex = regex
  }

  /// Whether the text matches the pattern anywhere.
  public func matches(_ text: String) -> Bool {
    text.contains(regex)
  }
}

/// The pattern of a rule or signal filter (`app`, `title`, `role`, `subrole`). regex is nil when the pattern is invalid.
public struct RulePattern: Equatable {
  public let text: String
  public let exclude: Bool
  public let regex: PatternRegex?

  public init(_ value: Token, exclude: Bool) {
    self.text = value.string
    self.exclude = exclude
    self.regex = PatternRegex(text)
  }

  /// Whether text passes the filter: it matches the pattern, or does not match an excluding one. An invalid pattern
  /// filters nothing.
  public func admits(_ text: String) -> Bool {
    guard let regex else { return true }
    return regex.matches(text) != exclude
  }

  //
  // NOTE: The regex is compiled from the text, so the text and the exclusion are the pattern. PatternRegex has no equality.
  //

  public static func == (lhs: RulePattern, rhs: RulePattern) -> Bool {
    lhs.text == rhs.text && lhs.exclude == rhs.exclude
  }
}
