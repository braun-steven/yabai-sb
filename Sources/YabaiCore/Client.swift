//
// NOTE: The message is the arguments argv[1..argc-1], each followed by a null byte, and an empty argument at the end,
// prefixed with the length of that payload (a native-endian int). The daemon reads it with get_token. Ported from
// client_encode_message in src/yabai.c.
//

public enum ClientMessage
{
    /// `client_encode_message`: the arguments after `-m`, as their bytes.
    public static func encode(_ arguments: [[UInt8]]) -> [UInt8]
    {
        let payloadLength = Int32(truncatingIfNeeded: arguments.reduce(1) { $0 + $1.count + 1 })

        // NOTE: the length's bytes in host order, as the daemon reads them; a byte copy of a plain integer.
        var message = withUnsafeBytes(of: payloadLength) { unsafe Array($0) }
        message.reserveCapacity(MemoryLayout<Int32>.size + Int(payloadLength))

        for argument in arguments {
            message += argument
            message.append(0)
        }
        message.append(0)

        return message
    }
}
