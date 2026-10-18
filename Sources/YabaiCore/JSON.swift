import CoreGraphics
import Darwin

//
// NOTE: The query responses keep the format of the original C serializers: key order, "%.4f" numbers, this escaping
// and the separators. The golden snapshot checks it; phase 5 of doc/swift-refactor.md moves queries to JSONEncoder.
//

public enum JSON
{
    private static let hex = Array("0123456789abcdef".utf8)

    /// `ts_string_escape`: the escaped bytes, or nil when nothing needs escaping. Bytes from 0x80 up pass through,
    /// like the signed chars of the C version.
    public static func escape(_ bytes: some Collection<UInt8>) -> [UInt8]?
    {
        guard bytes.contains(where: { $0 == UInt8(ascii: "\"") || $0 == UInt8(ascii: "\\") || $0 <= 0x1f }) else { return nil }

        var result: [UInt8] = []
        result.reserveCapacity(bytes.count + 8)

        for byte in bytes {
            switch byte {
            case UInt8(ascii: "\""): result += [UInt8(ascii: "\\"), UInt8(ascii: "\"")]
            case UInt8(ascii: "\\"): result += [UInt8(ascii: "\\"), UInt8(ascii: "\\")]
            case 0x08:               result += [UInt8(ascii: "\\"), UInt8(ascii: "b")]
            case 0x0c:               result += [UInt8(ascii: "\\"), UInt8(ascii: "f")]
            case UInt8(ascii: "\n"): result += [UInt8(ascii: "\\"), UInt8(ascii: "n")]
            case UInt8(ascii: "\r"): result += [UInt8(ascii: "\\"), UInt8(ascii: "r")]
            case UInt8(ascii: "\t"): result += [UInt8(ascii: "\\"), UInt8(ascii: "t")]
            case 0x00...0x1f:        result += [UInt8(ascii: "\\"), UInt8(ascii: "u"), UInt8(ascii: "0"), UInt8(ascii: "0"), hex[Int(byte >> 4)], hex[Int(byte & 0xf)]]
            default:                 result.append(byte)
            }
        }

        return result
    }

    /// `json_string`: a string for a json value, escaped when needed, and empty for nil.
    public static func string(_ s: String?) -> String
    {
        guard let s else { return "" }
        guard let escaped = escape(s.utf8) else { return s }
        return String(decoding: escaped, as: UTF8.self)
    }

    /// `json_bool`
    public static func bool(_ value: Bool) -> String
    {
        value ? "true" : "false"
    }

    /// A number as printf's "%.4f" formats it.
    public static func number(_ value: Double) -> String
    {
        var buffer = [CChar](repeating: 0, count: 32)
        let length = Int(withVaList([value]) { vsnprintf(&buffer, buffer.count, "%.4f", $0) })

        if length >= buffer.count {
            buffer = [CChar](repeating: 0, count: length + 1)
            _ = withVaList([value]) { vsnprintf(&buffer, buffer.count, "%.4f", $0) }
        }

        return String(decoding: buffer[0..<length].map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }

    /// `JSON_FRAME_FORMAT` with `JSON_FRAME_VALUES(frame)`
    public static func frame(_ frame: CGRect) -> String
    {
        "{\n\t\t\"x\":\(number(frame.origin.x)),\n\t\t\"y\":\(number(frame.origin.y)),\n\t\t\"w\":\(number(frame.size.width)),\n\t\t\"h\":\(number(frame.size.height))\n\t}"
    }
}

//
// NOTE: Writes one object of a query response, like the serializers that use JSON_PROPERTY: a "key":value pair is
// written only when its property is selected by flags, separated from the previous pair, and the value is only
// evaluated when the property is selected, because some values are expensive to query. The pair is the text after
// the tab of JSON_PROPERTY's format, e.g. "\"id\":\(did)". Like C, the caller turns flags 0 into "all properties"
// where the serializer did.
//

public struct JSONWriter
{
    public let flags: UInt64
    public private(set) var output = "{\n"
    private var separator = ""

    public init(flags: UInt64)
    {
        self.flags = flags
    }

    public mutating func property(_ property: UInt64, _ pair: @autoclosure () -> String)
    {
        guard flags & property != 0 else { return }

        output += separator
        output += "\t"
        output += pair()
        separator = ",\n"
    }

    /// The object, closed.
    public consuming func finish() -> String
    {
        output += "\n}"
        return output
    }
}
