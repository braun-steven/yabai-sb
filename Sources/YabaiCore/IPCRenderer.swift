/// The two independent CLI streams produced by one reply.
public struct CLIOutput: Equatable, Sendable {
  public var stdout = ""
  public var stderr = ""

  public init(stdout: String = "", stderr: String = "") {
    self.stdout = stdout
    self.stderr = stderr
  }
}

/// Validates response sequencing and renders wire envelopes without exposing them to CLI users.
public struct IPCRenderer: Sendable {
  private let request: IPCRequest
  private var failed = false
  private var lastCommand = 0
  public private(set) var completed = false
  public private(set) var subscribed = false

  public init(request: IPCRequest) { self.request = request }

  private func validIndex(_ index: Int) -> Bool {
    guard index >= lastCommand else { return false }
    switch request {
    case .command: return index == 1
    case .batch(let commands): return index > 0 && index <= commands.count
    }
  }

  public mutating func consume(_ reply: IPCReply) throws(IPCError) -> CLIOutput {
    guard !completed else { throw .invalidMessage }
    switch reply {
    case .output(let command, let data, let format):
      guard !subscribed, validIndex(command) else { throw .invalidMessage }
      lastCommand = command
      switch format {
      case .text:
        guard case .string(let text) = data else { throw .invalidMessage }
        return CLIOutput(stdout: text)
      case .json:
        return CLIOutput(stdout: try jsonLine(data))
      }
    case .error(let command, let message):
      guard !subscribed, command.map(validIndex) ?? true else { throw .invalidMessage }
      if let command { lastCommand = command }
      failed = true
      if request.isBatch, let command {
        var lines = message.split(separator: "\n", omittingEmptySubsequences: false)
        if lines.count > 1, lines.last?.isEmpty == true { lines.removeLast() }
        return CLIOutput(stderr: lines.map { "\(command): \($0)\n" }.joined())
      }
      return CLIOutput(stderr: message)
    case .complete(let ok):
      guard !subscribed, ok == !failed else { throw .invalidMessage }
      completed = true
      return CLIOutput()
    case .subscribed(let events):
      guard !subscribed, !failed,
        case .command(let arguments) = request, arguments.first == Domain.subscribe.rawValue
      else { throw .invalidMessage }
      subscribed = true
      return CLIOutput(stdout: try jsonLine(SubscribedLine(subscribed: events)))
    case .event(let data):
      guard subscribed else { throw .invalidMessage }
      return CLIOutput(stdout: try jsonLine(data))
    }
  }

  private func jsonLine(_ value: some Encodable) throws(IPCError) -> String {
    do { return String(decoding: try JSON.encode(value), as: UTF8.self) + "\n" } catch {
      throw .invalidMessage
    }
  }

  /// EOF is expected only after completion or after an acknowledged subscription.
  public func finish() throws(IPCError) -> Bool {
    guard completed || subscribed else { throw .incomplete }
    return !failed
  }
}
