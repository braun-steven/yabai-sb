import PropertyBased
import Testing

@testable import YabaiCore

//
// NOTE: Differential tests of the Swift number parsers (`TokenScan.swift`) against the libc parsers they replaced
// (LibcScanOracle.swift), one row per format of the message parsers. Each run must agree on the number of conversions
// that matched and on the values, bit for bit (any two NaNs agree). The inputs mix the edge cases that the formats
// reach: signs, exponents, hexadecimal floats, inf and nan, overflowing integers, white space and long fields.
//

/// A format of a message parser, the same one the call site uses: the field, and the conversions after it.
struct ScanShape: Sendable {
  let name: String
  let format: String
  let field: Int?
  let count: Int
}

/// The integer formats. Each row's format is the sscanf format of the call site (SpaceCommand, WindowCommand, Rule,
/// MessageConfig).
private let integerShapes: [ScanShape] = [
  ScanShape(name: "space padding", format: "%255[^:]:%d:%d:%d:%d", field: 255, count: 4),
  ScanShape(name: "space gap", format: "%255[^:]:%d", field: 255, count: 1),
  ScanShape(name: "grid", format: "%d:%d:%d:%d:%d:%d", field: nil, count: 6),
  ScanShape(name: "external bar", format: "%5[^:]:%d:%d", field: 5, count: 2),
]

/// The float formats: move and resize, ratio, and the single `%f` of the opacity rule and the tab bar font.
private let floatShapes: [ScanShape] = [
  ScanShape(name: "move and resize", format: "%255[^:]:%f:%f", field: 255, count: 2),
  ScanShape(name: "ratio", format: "%255[^:]:%f", field: 255, count: 1),
  ScanShape(name: "single float", format: "%f", field: nil, count: 1),
]

/// The inputs that the formats reach at their edges, checked on every format.
private let edgeTokens: [String] = [
  "", " ", "1", "-0", "+", "-", ".", "e5", "1e", "1e+", "1e5x", "1e+5e", "0x", "0x1p3", "0x.p0",
  "0x1.p0", "0x1p",
  "0X1F", "0x1P-2", "0x1ffffff", "0x123456789abcdef0123", "0x.8", "0xp1", "1.5.5", "1..5", "5.",
  ".5", "-.5",
  "-.e5", "0.1e-45", "3.4028235677973367e38", "3.4028235677973366e38", "1e40",
  "1e-99999999999999999999",
  "00000000000000000000000000000001.5", "inf", "-infinity", "infinit", "infx", "INF", "Infinity",
  "nan", "-nan",
  "nan()", "nan(a b)", "nan(1", "NaN(_1)", "nanx", "in", "i", "  12x", "\t5", "\u{0B}1", " -7",
  " +7",
  "9999999999", "2147483647", "2147483648", "-2147483648", "-2147483649", "4294967296",
  "3000000000",
  "9223372036854775807", "9223372036854775808", "-9223372036854775808", "-9223372036854775809",
  "-99999999999999999999", "99999999999999999999999", "1:2:3:4:5:6", "1:2:3:4:5", "-1:2:bad:4:5:6",
  "move:1e:2", "move: 1:2", "move:1:2:3", "a:1:2", ":1:2", "x:1e5:2", "x:0x1p3:-inf", "x:nan:1",
  "inf:", "nan:1",
  "é:1:2", "e\u{301}:1:2", "a\u{FFFD}:1", "left:1:2:3:4", "bottom:-3:9", "sys:1", "1e5:6",
  String(repeating: "a", count: 300) + ":1:2", String(repeating: "7", count: 300),
  String(repeating: "x", count: 255) + ":1:2", String(repeating: "x", count: 256) + ":1:2",
]

/// Bytes of random inputs: digits and the characters of numbers, colons, white space, letters of inf and nan, and
/// two bytes that are not valid UTF-8 on their own.
private let scanAlphabet: [UInt8] =
  Array("0123456789:-+.eExXpPinfINFtyaA()_ \t".utf8) + [0xC3, 0xA9, 0xFF, 0x80]

/// Bytes of a field: the alphabet without the colon.
private let fieldAlphabet: [UInt8] = scanAlphabet.filter { $0 != UInt8(ascii: ":") }

/// Words that the numbers are made of, including the partial ones.
private let scanWords: [[UInt8]] = [
  "inf", "infinity", "nan", "nan(", "nan()", "0x", "0x1p", "0x.", "1e", "1e+", "1e-", "-", "+", ".",
  "e5", "0",
  "9223372036854775808", "4294967296", "2147483648", "2147483647", ":", "::", "nan(a b)", "nan(a)",
  "nan(é)",
].map { Array($0.utf8) }

/// One element of choices, picked by index, so that a failing input shrinks towards the first one.
private func pick<Element: Sendable>(_ choices: [Element]) -> Generator<
  Element, Shrink.Integer<Int>
> {
  Gen<Int>.int(in: 0...(choices.count - 1)).map { choices[$0] }
}

/// Random runs of the alphabet, words with a random run, and a long field followed by a word.
private let runGenerator = pick(scanAlphabet).array(of: 0...12).eraseToAny()
private let wordGenerator = pick(scanWords).eraseToAny()
private let wordAndRunGenerator = zip(pick(scanWords), pick(scanAlphabet).array(of: 0...6))
  .map { (word: [UInt8], run: [UInt8]) -> [UInt8] in word + run }
  .eraseToAny()
private let longFieldGenerator = zip(pick(fieldAlphabet).array(of: 250...300), pick(scanWords))
  .map { (field: [UInt8], tail: [UInt8]) -> [UInt8] in field + [UInt8(ascii: ":")] + tail }
  .eraseToAny()

/// Numbers that the formats accept, most of the time, so that the inputs reach every conversion of a format.
private let validNumberWords: [[UInt8]] = [
  "0", "-1", "+5", " 7", "\t8", "2147483647", "-2147483648", "1e3", "0x1p3", "-.5", "1.5", "5.",
  "0X1F", "inf", "-inf",
  "nan", "-0", "0.25", "1e-5", "3.4028235677973366e38", "0x.8", "nan(a)",
].map { Array($0.utf8) }

/// Numbers that the formats reject or read only in part.
private let invalidNumberWords: [[UInt8]] = [
  "2147483648", "-2147483649", "4294967296", "99999999999999999999", "-99999999999999999999", "12x",
  "1e", "1e+",
  "0x", "nan(a b)", "infx", "", "e", ".", "-", "+",
].map { Array($0.utf8) }

/// Field texts, mostly empty: a format with a field and one without both take the inputs.
private let fieldPrefixes: [[UInt8]] = [
  "", "", "", "", "move", "left", "x", "é", "e\u{301}", "a b", "\u{FFFD}",
].map { Array($0.utf8) }

/// A number of a format: mostly valid ones, sometimes a broken one.
private let numberGenerator = Gen<[UInt8]>.frequency(
  (5, pick(validNumberWords).eraseToAny()),
  (1, pick(invalidNumberWords).eraseToAny())
)

/// Well-formed inputs: an optional field, then one to seven numbers separated by colons.
private let structuredGenerator = zip(pick(fieldPrefixes), numberGenerator.array(of: 1...7))
  .map { (field: [UInt8], numbers: [[UInt8]]) -> [UInt8] in
    let colon: [UInt8] = [UInt8(ascii: ":")]
    return (field.isEmpty ? [] : field + colon) + numbers.joined(separator: colon)
  }
  .eraseToAny()

/// The inputs of the differential properties: structured ones, and random runs, words and long fields.
private let scanInputGenerator = Gen<[UInt8]>.oneOf(
  structuredGenerator,
  runGenerator,
  wordGenerator,
  wordAndRunGenerator,
  longFieldGenerator
)

/// A value that the differential compares: NaNs agree with each other, other floats by their bit pattern.
private protocol LibcComparable {
  static func agrees(_ lhs: Self, _ rhs: Self) -> Bool
}

extension Int32: LibcComparable {
  static func agrees(_ lhs: Int32, _ rhs: Int32) -> Bool { lhs == rhs }
}

extension Float: LibcComparable {
  static func agrees(_ lhs: Float, _ rhs: Float) -> Bool {
    (lhs.isNaN && rhs.isNaN) || lhs.bitPattern == rhs.bitPattern
  }
}

/// Checks the count of matched conversions, the field and the numbers of the Swift parser against the libc result.
/// libc returns -1 when the input ends before any conversion matched; the Swift parser returns 0 there.
private func expectAgreement<Number: LibcComparable>(
  _ token: Token, _ shape: ScanShape, libc: LibcScan<Number>, swift: ScanResult<Number>
) {
  let expected = libc.returned == -1 ? 0 : libc.returned
  let context = "\(shape.name) on \(token.string.debugDescription)"

  #expect(
    swift.assigned == expected,
    "assigned \(swift.assigned) against libc \(libc.returned) for \(context)")
  guard swift.assigned == expected else { return }

  let hasField = shape.field != nil && expected > 0
  if hasField {
    #expect(
      swift.field?.string == libc.field,
      "field \(String(describing: swift.field?.string)) against libc '\(libc.field)' for \(context)"
    )
  }

  let numbers = expected - (hasField ? 1 : 0)
  #expect(
    swift.values.count == numbers, "\(swift.values.count) numbers against \(numbers) for \(context)"
  )
  for index in 0..<min(numbers, swift.values.count) {
    #expect(
      Number.agrees(swift.values[index], libc.values[index]),
      "number \(index) is \(swift.values[index]) against libc \(libc.values[index]) for \(context)")
  }
}

private func expectSameIntegers(_ token: Token, _ shape: ScanShape) {
  let libc = LibcOracle.integers(token, shape.format, field: shape.field != nil, count: shape.count)
  expectAgreement(
    token, shape, libc: libc, swift: token.scanIntegers(field: shape.field, count: shape.count))
}

private func expectSameFloats(_ token: Token, _ shape: ScanShape) {
  let libc = LibcOracle.floats(token, shape.format, field: shape.field != nil, count: shape.count)
  expectAgreement(
    token, shape, libc: libc, swift: token.scanFloats(field: shape.field, count: shape.count))
}

private func expectSameWhole(_ token: Token) {
  let libc = LibcOracle.whole(token)
  let swift = token.float
  switch (libc, swift) {
  case (nil, nil):
    break
  case (let value?, let other?):
    #expect(
      Float.agrees(value, other),
      "\(other) against libc \(value) for \(token.string.debugDescription)")
  default:
    #expect(
      Bool(false),
      "\(String(describing: swift)) against libc \(String(describing: libc)) for \(token.string.debugDescription)"
    )
  }
}

@Suite struct TokenScanTests {
  @Test(arguments: integerShapes)
  func integerFormatsAgreeWithLibc(_ shape: ScanShape) async {
    await propertyCheck(count: 3000, input: scanInputGenerator) { bytes in
      expectSameIntegers(Token(bytes), shape)
    }
  }

  @Test(arguments: floatShapes)
  func floatFormatsAgreeWithLibc(_ shape: ScanShape) async {
    await propertyCheck(count: 3000, input: scanInputGenerator) { bytes in
      expectSameFloats(Token(bytes), shape)
    }
  }

  @Test func wholeTokenFloatAgreesWithLibc() async {
    await propertyCheck(count: 3000, input: scanInputGenerator) { bytes in
      // An empty token is never parsed as a number: `value` checks for it first.
      guard !bytes.isEmpty else { return }
      expectSameWhole(Token(bytes))
    }
  }

  @Test func edgeTokensAgreeWithLibcOnEveryFormat() {
    for text in edgeTokens {
      let token = Token(text)
      for shape in integerShapes { expectSameIntegers(token, shape) }
      for shape in floatShapes { expectSameFloats(token, shape) }
      if !text.isEmpty { expectSameWhole(token) }
    }
  }
}
