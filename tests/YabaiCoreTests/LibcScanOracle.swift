import Darwin
import YabaiCore

//
// NOTE: The libc parsers that the Swift token parsers (`TokenScan.swift`) replaced, kept as the oracle of the
// differential tests in TokenScanTests.swift. Nothing in Sources calls them. Their results are the reference: a
// failing differential property is fixed in the Swift parser, never here.
//

/// The result of a libc scan: the return value of the scanning function (-1 at the end of the input), the text of the
/// `%N[^:]` field and the numbers it converted, one per conversion of the format.
struct LibcScan<Number>
{
    var returned: Int
    var field: String
    var values: [Number]
}

enum LibcOracle
{
    /// vsscanf of a format of `%d` conversions on the token, with an optional `%N[^:]` field first.
    static func integers(_ token: Token, _ format: String, field: Bool, count: Int) -> LibcScan<Int32>
    {
        run(token, format, field: field, count: count, initial: 0)
    }

    /// vsscanf of a format of `%f` conversions on the token, with an optional `%N[^:]` field first.
    static func floats(_ token: Token, _ format: String, field: Bool, count: Int) -> LibcScan<Float>
    {
        run(token, format, field: field, count: count, initial: 0)
    }

    /// strtof of the whole token: the value when the conversion reads all of it.
    static func whole(_ token: Token) -> Float?
    {
        token.string.withCString { text in
            var end: UnsafeMutablePointer<CChar>? = nil
            let value = strtof(text, &end)
            guard let end, end.pointee == 0 else { return nil }
            return value
        }
    }

    private static func run<Number>(_ token: Token, _ format: String, field: Bool, count: Int, initial: Number) -> LibcScan<Number>
    {
        var buffer = [CChar](repeating: 0, count: 512)
        var numbers = [Number](repeating: initial, count: count)

        let returned = buffer.withUnsafeMutableBufferPointer { text in
            numbers.withUnsafeMutableBufferPointer { values in
                var arguments: [CVarArg] = []
                if field { arguments.append(text.baseAddress!) }
                for index in 0..<values.count { arguments.append(values.baseAddress! + index) }
                return Int(token.string.withCString { input in withVaList(arguments) { vsscanf(input, format, $0) } })
            }
        }

        let bytes = buffer.prefix(while: { $0 != 0 }).map { UInt8(bitPattern: $0) }
        return LibcScan(returned: returned, field: String(decoding: bytes, as: UTF8.self), values: numbers)
    }
}
