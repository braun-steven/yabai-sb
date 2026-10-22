//
// NOTE: The numbers of the message arguments, read the way sscanf reads the formats the parsers used to pass it. `%d`
// and `%f` skip white space, `%N[^:]` takes up to N bytes that are not colons (and no white space is skipped), and a
// colon of a format matches only the next byte. The first mismatch ends the read, and the conversions that matched
// before it are kept. A float is the longest prefix that the C float grammar accepts (decimal, hexadecimal, inf, nan),
// converted by Swift, which rounds like the C conversion.
//

/// The conversions of a format that a token matched.
public struct ScanResult<Number: Sendable>: Sendable
{
    /// The number of conversions that matched before the first mismatch, the field included. Zero also where the input
    /// ended first, which the C scanning function reports as -1.
    public var assigned = 0
    /// The text of the field, when the format starts with one and it matched.
    public var field: Token?
    /// The numbers that matched, in order.
    public var values: [Number] = []
}

extension Token
{
    /// The conversions `%<fieldMax>[^:]:%d:…`, or `%d:…` without a field, with `count` integers. The field is at most
    /// `fieldMax` bytes that are not colons. A number that follows the field, or another number, is preceded by a colon.
    public func scanIntegers(field fieldMax: Int? = nil, count: Int) -> ScanResult<Int32>
    {
        var reader = TokenReader(self)
        return reader.read(field: fieldMax, count: count) { $0.takeInteger() }
    }

    /// The same shape as `scanIntegers`, with `%f` numbers.
    public func scanFloats(field fieldMax: Int? = nil, count: Int) -> ScanResult<Float>
    {
        var reader = TokenReader(self)
        return reader.read(field: fieldMax, count: count) { $0.takeFloat() }
    }

    /// The whole token as a float: a float that starts after the white space and ends at the end of the token. Nil for
    /// an empty token and for a token with anything left over.
    public var float: Float?
    {
        var reader = TokenReader(self)
        guard let value = reader.takeFloat(wholeToken: true), reader.isAtEnd else { return nil }
        return value
    }
}

/// The bytes of a token and the position that the conversions have read up to.
private struct TokenReader
{
    private static let colon = UInt8(ascii: ":")
    private static let plus = UInt8(ascii: "+")
    private static let minus = UInt8(ascii: "-")
    private static let point = UInt8(ascii: ".")

    private let bytes: [UInt8]
    private var position = 0

    init(_ token: Token)
    {
        bytes = Array(token.utf8)
    }

    var isAtEnd: Bool { position == bytes.count }

    /// The format of the conversions: a field when `fieldMax` is given, then `count` numbers. `number` reads one.
    mutating func read<Number>(field fieldMax: Int?, count: Int, number: (inout TokenReader) -> Number?) -> ScanResult<Number>
    {
        var result = ScanResult<Number>()

        if let fieldMax {
            guard let text = takeField(max: fieldMax) else { return result }
            result.field = text
            result.assigned = 1
        }

        for index in 0..<count {
            if index > 0 || fieldMax != nil {
                guard takeColon() else { return result }
            }
            guard let value = number(&self) else { return result }
            result.values.append(value)
            result.assigned += 1
        }

        return result
    }

    /// `%<max>[^:]`: one to `max` bytes that are not colons.
    private mutating func takeField(max: Int) -> Token?
    {
        let start = position
        while position - start < max, let byte = peek(at: position), byte != Self.colon {
            position += 1
        }

        guard position > start else { return nil }
        return Token(bytes[start..<position])
    }

    private mutating func takeColon() -> Bool
    {
        guard peek(at: position) == Self.colon else { return false }
        position += 1
        return true
    }

    /// `%d`: white space, an optional sign, then decimal digits. The digits are summed in 64 bits, saturating there
    /// like strtoimax does, and the value keeps its low 32 bits, as the C int it was read into does.
    mutating func takeInteger() -> Int32?
    {
        skipSpace()
        let negative = takeSign()

        let limit: UInt64 = 1 << 63
        var magnitude: UInt64 = 0
        var digits = 0
        while let byte = peek(at: position), isDecimalDigit(byte) {
            let digit = UInt64(byte - UInt8(ascii: "0"))
            magnitude = magnitude > limit / 10 ? limit : min(magnitude * 10 + digit, limit)
            digits += 1
            position += 1
        }

        guard digits > 0 else { return nil }

        let value: Int64
        if negative {
            value = magnitude >= limit ? .min : -Int64(magnitude)
        } else {
            value = magnitude >= limit ? .max : Int64(magnitude)
        }
        return Int32(truncatingIfNeeded: value)
    }

    /// `%f`: white space, an optional sign, then `inf` or `infinity`, `nan` with an optional `(n-char-sequence)`, or a
    /// decimal or hexadecimal number. Each reads the longest prefix that matches, so `1e` reads `1` and `0x` reads `0`.
    /// `wholeToken` is the whole-token float, whose nan payload runs to the first closing parenthesis, not only over
    /// letters, digits and underscores.
    mutating func takeFloat(wholeToken: Bool = false) -> Float?
    {
        skipSpace()
        let negative = takeSign()

        let magnitude: Float
        if takeWord("infinity") || takeWord("inf") {
            magnitude = .infinity
        } else if takeWord("nan") {
            takeNanPayload(wholeToken: wholeToken)
            magnitude = .nan
        } else {
            guard let number = takeNumber() else { return nil }
            magnitude = number
        }

        return negative ? -magnitude : magnitude
    }

    private mutating func skipSpace()
    {
        while let byte = peek(at: position), isSpace(byte) {
            position += 1
        }
    }

    /// Consumes the sign, if any; true for a minus.
    private mutating func takeSign() -> Bool
    {
        guard let byte = peek(at: position), byte == Self.plus || byte == Self.minus else { return false }
        position += 1
        return byte == Self.minus
    }

    /// Consumes `word` in any letter case, only when all of it matches.
    private mutating func takeWord(_ word: String) -> Bool
    {
        let letters = Array(word.utf8)
        for (offset, letter) in letters.enumerated() {
            guard let byte = peek(at: position + offset), (byte | 0x20) == letter else { return false }
        }

        position += letters.count
        return true
    }

    /// The `(n-char-sequence)` after nan. In a conversion it is letters, digits and underscores up to a closing
    /// parenthesis; in the whole token it is any bytes up to the first closing parenthesis. Without the closing
    /// parenthesis it is not read.
    private mutating func takeNanPayload(wholeToken: Bool)
    {
        guard peek(at: position) == UInt8(ascii: "(") else { return }

        var end = position + 1
        if wholeToken {
            while let byte = peek(at: end), byte != UInt8(ascii: ")") { end += 1 }
        } else {
            while let byte = peek(at: end), isAlphanumeric(byte) || byte == UInt8(ascii: "_") { end += 1 }
        }

        guard peek(at: end) == UInt8(ascii: ")") else { return }
        position = end + 1
    }

    /// A decimal or hexadecimal number, without its sign. Nil when it has no digit.
    private mutating func takeNumber() -> Float?
    {
        if peek(at: position) == UInt8(ascii: "0"), let marker = peek(at: position + 1), (marker | 0x20) == UInt8(ascii: "x") {
            return takeHexadecimal()
        }
        return takeDecimal()
    }

    /// `0x`, hexadecimal digits with an optional point, and an optional binary exponent. Without a digit only the `0`
    /// is read, and the value is zero.
    private mutating func takeHexadecimal() -> Float?
    {
        let start = position
        var end = start + 2
        var digits = 0
        while let byte = peek(at: end), isHexadecimalDigit(byte) {
            end += 1
            digits += 1
        }

        if peek(at: end) == Self.point {
            var fraction = end + 1
            var fractionDigits = 0
            while let byte = peek(at: fraction), isHexadecimalDigit(byte) {
                fraction += 1
                fractionDigits += 1
            }
            if digits + fractionDigits > 0 {
                end = fraction
                digits += fractionDigits
            }
        }

        guard digits > 0 else {
            position = start + 1
            return 0
        }

        end = exponentEnd(after: end, marker: UInt8(ascii: "p"))
        position = end
        return number(from: start, to: end)
    }

    /// Decimal digits with an optional point and an optional exponent. Nil when there is no digit.
    private mutating func takeDecimal() -> Float?
    {
        let start = position
        var end = start
        var digits = 0
        while let byte = peek(at: end), isDecimalDigit(byte) {
            end += 1
            digits += 1
        }

        if peek(at: end) == Self.point {
            end += 1
            while let byte = peek(at: end), isDecimalDigit(byte) {
                end += 1
                digits += 1
            }
        }

        guard digits > 0 else { return nil }

        end = exponentEnd(after: end, marker: UInt8(ascii: "e"))
        position = end
        return number(from: start, to: end)
    }

    /// The end of an exponent that starts at `index` with `marker` (e or p, either case), an optional sign and one or
    /// more decimal digits. Without them, `index`: the marker is not read.
    private func exponentEnd(after index: Int, marker: UInt8) -> Int
    {
        guard let byte = peek(at: index), (byte | 0x20) == marker else { return index }

        var end = index + 1
        if let sign = peek(at: end), sign == Self.plus || sign == Self.minus { end += 1 }

        var digits = 0
        while let digit = peek(at: end), isDecimalDigit(digit) {
            end += 1
            digits += 1
        }

        return digits > 0 ? end : index
    }

    /// The float of the unsigned number in bytes start..<end. Swift rounds it like C's conversion. The text is ASCII
    /// after lowercasing, so Swift's parser reads the `0x` and `p` forms.
    private func number(from start: Int, to end: Int) -> Float?
    {
        Float(String(decoding: bytes[start..<end], as: UTF8.self).lowercased())
    }

    private func peek(at index: Int) -> UInt8?
    {
        index < bytes.count ? bytes[index] : nil
    }
}

private func isSpace(_ byte: UInt8) -> Bool
{
    byte == 0x20 || (0x09...0x0D).contains(byte)
}

private func isDecimalDigit(_ byte: UInt8) -> Bool
{
    (UInt8(ascii: "0")...UInt8(ascii: "9")).contains(byte)
}

private func isHexadecimalDigit(_ byte: UInt8) -> Bool
{
    isDecimalDigit(byte) || ((byte | 0x20) >= UInt8(ascii: "a") && (byte | 0x20) <= UInt8(ascii: "f"))
}

private func isAlphanumeric(_ byte: UInt8) -> Bool
{
    isDecimalDigit(byte) || ((byte | 0x20) >= UInt8(ascii: "a") && (byte | 0x20) <= UInt8(ascii: "z"))
}
