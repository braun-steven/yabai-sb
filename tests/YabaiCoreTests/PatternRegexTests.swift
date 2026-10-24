import Testing
import YabaiTestSupport

@testable import YabaiCore

//
// NOTE: Rows of (pattern, text, matches). The first rows are the kinds of patterns of a typical yabai.toml, which match
// as they did with regcomp; the others are what Swift Regex changed: characters instead of bytes, and the added syntax.
//

@Test(
  arguments: [
    ("^Safari$", "Safari", true),
    ("^Safari$", "Safari Technology Preview", false),
    ("^[Tt]hunderbird$", "thunderbird", true),
    ("Settings$", "Xcode Settings", true),
    ("^General.*", "General", true),
    (".*WhatsApp.*", "WhatsApp", true),
    ("^$", "", true),
    ("^$", "x", false),
    ("Sign in - Google", "Sign in - Google Accounts — Firefox", true),
    ("^.$", "é", true),
    ("^.$", "👩‍💻", true),
    ("^Ünïcödé$", "Ünïcödé", true),
    ("(?i)^safari$", "Safari", true),
    ("^safari$", "Safari", false),
    ("^Window \\d+$", "Window 12", true),
    ("\\bNotes\\b", "Apple Notes", true),
    ("^(?!Preferences$)", "Preferences", false),
  ])
func patternMatches(_ pattern: String, _ text: String, _ matches: Bool) throws {
  let regex = try #require(PatternRegex(pattern))
  #expect(regex.matches(text) == matches)
}

@Test(arguments: ["(", "[a", "a{2,1}", "*"])
func invalidPatternIsRejected(_ pattern: String) {
  #expect(PatternRegex(pattern) == nil)
}
