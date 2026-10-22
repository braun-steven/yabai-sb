import Foundation

/// The json of query responses.
public enum JSON
{
    //
    // NOTE: JSONEncoder does not keep the order in which encode(to:) writes keys: without .sortedKeys the order follows
    // hashing and changes between encodings of the same value. Query responses therefore sort their keys. Non-finite
    // numbers are written as the strings "nan", "inf" and "-inf", so encoding the query types cannot fail.
    //

    /// The compact json of a query response, with sorted keys and unescaped slashes.
    public static func encode(_ value: some Encodable) throws(CommandError) -> [UInt8]
    {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        encoder.nonConformingFloatEncodingStrategy = .convertToString(positiveInfinity: "inf", negativeInfinity: "-inf", nan: "nan")

        do {
            return Array(try encoder.encode(value))
        } catch {
            throw CommandError("could not encode query json\n")
        }
    }
}
