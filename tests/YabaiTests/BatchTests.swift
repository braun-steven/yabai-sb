import Testing
import YabaiCore

@testable import Yabai

@WM private func batchOutput(_ commands: [[String]]) throws -> (output: CLIOutput, ok: Bool) {
  let request = IPCRequest.batch(commands: commands)
  var renderer = IPCRenderer(request: request)
  var output = CLIOutput()
  let results = executeRequest(request)
  for result in results {
    for entry in result.response.entries {
      let reply = try IPCProtocol.decode(
        IPCReply.self, payload: JSON.encode(IPCOutput(command: result.command, entry: entry)))
      let part = try renderer.consume(reply)
      output.stdout += part.stdout
      output.stderr += part.stderr
    }
  }
  _ = try renderer.consume(.complete(ok: results.allSatisfy { $0.response.failures.isEmpty }))
  return (output, try renderer.finish())
}

extension DaemonState {
  @Suite @WM struct BatchTests {
    @Test func outputOfCommandsKeepsItsOrder() throws {
      let result = try batchOutput([["config", "debug_output"], ["config", "window_gap"]])
      #expect(result.output.stdout == "off\n0\n")
      #expect(result.output.stderr.isEmpty)
      #expect(result.ok)
    }

    @Test func failuresKeepTheirIndicesWithoutRedirectingSuccesses() throws {
      let result = try batchOutput([
        ["config", "window_gap", "x"], ["config", "debug_output"], ["config", "layout", "bogus"],
      ])
      #expect(result.output.stdout == "off\n")
      #expect(
        result.output.stderr
          == "1: unknown value 'x' given to command 'window_gap' for domain 'config'; expected a non-negative integer\n"
          + "3: unknown value 'bogus' given to command 'layout' for domain 'config'; expected one of: float, tree\n"
      )
      #expect(!result.ok)
    }

    @Test func chainedCommandsExecuteAfterEarlierChangesAndErrors() throws {
      let result = try batchOutput([
        ["config", "debug_output", "on", "window_gap", "x", "window_gap", "12"],
        ["config", "debug_output"], ["config", "window_gap"],
      ])
      #expect(result.output.stdout == "on\n12\n")
      #expect(result.output.stderr.hasPrefix("1: unknown value 'x'"))
      #expect(!result.ok)
    }

    @Test func emptyArgumentsReachTheCommandParser() throws {
      let result = try batchOutput([["rule", "--remove", ""]])
      #expect(result.output.stderr == "1: value '' is not a valid option for RULE_SEL\n")
      #expect(!result.ok)
    }

    @Test(arguments: [
      (["batch"], "batch: a batch cannot contain a batch\n"),
      (["subscribe"], "batch: subscribe keeps its client connected and cannot run in a batch\n"),
    ])
    func connectionChangingCommandsAreRefused(_ command: [String], _ failure: String) throws {
      let result = try batchOutput([["config", "debug_output"], command])
      #expect(result.output.stdout == "off\n")
      #expect(result.output.stderr == "2: " + failure)
      #expect(!result.ok)
      #expect(EventSubscribers.shared.subscribers.isEmpty)
    }

    @Test func checkReportsABatchAsUnchecked() {
      var message = Message(arguments: ["batch"])
      let check = checkMessage(&message)
      #expect(check.failures.isEmpty)
      #expect(check.notes == ["not checked: batch commands are checked when they run"])
    }
  }
}
