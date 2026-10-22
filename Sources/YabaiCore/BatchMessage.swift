//
// NOTE: `yabai -m batch` sends several commands in one message. After the domain token `batch`, each command is a
// decimal count of its tokens followed by those tokens: `batch 4 window --focus "" west 1 space`. The count says where
// a command ends, so an empty token inside a command is one of its arguments. A count of 0 is refused, because a
// command with no tokens has no domain to run. An empty argument is accepted, and the command parser decides whether
// it is valid.
//
// NOTE: The count token is decimal digits only: no sign, no hexadecimal, no fraction and no white space. Leading zeros
// are accepted (`01` is 1), and a count beyond Int is malformed.
//

/// The tokens of a batch message: `encode` for the client, `decode` for the daemon.
public enum BatchMessage
{
    /// The domain token that starts a batch message.
    public static let domain = "batch"

    /// The tokens of a batch message for the commands, each command as its tokens: the domain token, then a count
    /// and the tokens of each command. `ClientMessage.encode` takes these tokens as its arguments.
    public static func encode(_ commands: [[String]]) -> [[UInt8]]
    {
        var tokens: [[UInt8]] = [Array(domain.utf8)]
        for command in commands {
            tokens.append(Array(String(command.count).utf8))
            tokens += command.map { Array($0.utf8) }
        }
        return tokens
    }

    /// The commands of a batch message, from the tokens after the domain token (`encode` without its first token).
    ///
    /// Fails for no commands at all, for a count that is not decimal, for a count of 0, and for a count that is larger
    /// than the tokens that follow it.
    public static func decode(_ tokens: [[UInt8]]) throws(BatchError) -> [[Token]]
    {
        guard !tokens.isEmpty else { throw .emptyBatch }

        var commands: [[Token]] = []
        var index = 0
        while index < tokens.count {
            let command = commands.count + 1
            guard let count = decimalCount(tokens[index]) else {
                throw .malformedCount(command: command, Token(tokens[index]))
            }
            guard count > 0 else { throw .emptyCommand(command: command) }

            index += 1
            let remaining = tokens.count - index
            guard count <= remaining else {
                throw .countExceedsTokens(command: command, count: count, remaining: remaining)
            }

            commands.append(tokens[index..<index + count].map { Token($0) })
            index += count
        }
        return commands
    }

    /// The value of a count token, or nil when it is empty or has a byte that is not a decimal digit or is beyond Int.
    private static func decimalCount(_ bytes: [UInt8]) -> Int?
    {
        guard !bytes.isEmpty, bytes.allSatisfy({ $0 >= UInt8(ascii: "0") && $0 <= UInt8(ascii: "9") }) else { return nil }
        return Int(String(decoding: bytes, as: UTF8.self))
    }
}

/// Why a batch message could not be decoded. `message` is the response text, without a newline.
public enum BatchError: Error, Equatable, Sendable
{
    /// The batch has no tokens after `batch`.
    case emptyBatch
    /// The count of a command is not a decimal number. `command` is 1-based.
    case malformedCount(command: Int, Token)
    /// The count of a command is 0, so it has no tokens.
    case emptyCommand(command: Int)
    /// The count of a command is larger than the tokens left in the batch.
    case countExceedsTokens(command: Int, count: Int, remaining: Int)

    public var message: String
    {
        switch self {
        case .emptyBatch:
            return "batch: no commands given"
        case .malformedCount(let command, let token):
            return "batch: command \(command) has the count '\(token.string)', expected a decimal number"
        case .emptyCommand(let command):
            return "batch: command \(command) has no tokens"
        case .countExceedsTokens(let command, let count, let remaining):
            return "batch: command \(command) has \(count) tokens, but only \(remaining) follow"
        }
    }
}
