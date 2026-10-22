import Testing
import YabaiCore
@testable import Yabai

//
// NOTE: `yabai -m batch` (handleDomainBatch in IPC/MessageLoop.swift) on the daemon state of the fixture: each command
// runs through handleMessage, so the rows here fail before they act, or only change the daemon's own state (config).
// The message is built as the daemon reads it from a client: the payload with the two padding nulls of readMessage.
//

/// The message the daemon reads for these raw tokens, as readMessage gives it.
@WM private func rawMessage(_ tokens: [[UInt8]]) -> Message
{
    Message(Array(ClientMessage.encode(tokens).dropFirst(MemoryLayout<Int32>.size)) + [0, 0])
}

/// The response of the daemon to a batch message with these raw tokens, the domain token first.
@WM private func runRawBatch(_ tokens: [[UInt8]]) -> [UInt8]
{
    var response = Response()
    var message = rawMessage(tokens)
    handleMessage(&response, &message)
    return response.bytes
}

/// The response of the daemon to `yabai -m batch` with these commands.
@WM private func runBatch(_ commands: [[String]]) -> [UInt8]
{
    runRawBatch(BatchMessage.encode(commands))
}

private func text(_ bytes: [UInt8]) -> String
{
    String(decoding: bytes, as: UTF8.self)
}

extension DaemonState
{
    @Suite
    @WM struct BatchTests
    {
        @Test func outputOfTheCommandsIsConcatenatedInOrder()
        {
            DaemonFixture.reset()
            let expected = Golden.run("config debug_output") + Golden.run("config window_gap")
            #expect(runBatch([["config", "debug_output"], ["config", "window_gap"]]) == expected)
        }

        //
        // NOTE: The second command runs after the first one fails, and its output keeps its place between the failure
        // lines. The failure byte is the only one in the response, in front of everything.
        //

        @Test func failuresArePrefixedWithTheIndexOfTheirCommandUnderOneFailureByte()
        {
            DaemonFixture.reset()
            let response = runBatch([["config", "window_gap", "x"], ["config", "debug_output"], ["config", "layout", "bogus"]])
            let expected = "\u{07}1: unknown value 'x' given to command 'window_gap' for domain 'config'; expected a non-negative integer\n"
                + "off\n"
                + "3: unknown value 'bogus' given to command 'layout' for domain 'config'; expected one of: float, tree\n"
            #expect(text(response) == expected)
            #expect(response.filter { $0 == Response.failureByte }.count == 1)
        }

        @Test func aFailureInAChainedCommandIsPrefixedWithTheCommandIndex()
        {
            DaemonFixture.reset()
            let response = runBatch([["config", "debug_output", "on", "window_gap", "x"]])
            #expect(text(response) == "\u{07}1: unknown value 'x' given to command 'window_gap' for domain 'config'; expected a non-negative integer\n")
        }

        // NOTE: An empty argument reaches the command's parser as an argument: `rule --remove ''` fails on its empty selector.
        @Test func anEmptyArgumentIsAnArgumentOfItsCommand()
        {
            DaemonFixture.reset()
            #expect(text(runBatch([["rule", "--remove", ""]]))
                == "\u{07}1: value '' is not a valid option for RULE_SEL\n")
        }

        @Test func aBatchCannotContainABatch()
        {
            DaemonFixture.reset()
            #expect(text(runBatch([["config", "debug_output"], ["batch", "config", "debug_output"]]))
                == "\u{07}off\n2: batch: a batch cannot contain a batch\n")
        }

        @Test func aBatchWithoutFailuresHasNoFailureByte()
        {
            DaemonFixture.reset()
            #expect(!runBatch([["config", "debug_output", "on"]]).contains(Response.failureByte))
        }

        // NOTE: The whole batch is decoded before its first command runs, so a malformed count writes no command output.
        @Test(arguments: [
            (["batch"], "batch: no commands given\n"),
            (["batch", "x"], "batch: command 1 has the count 'x', expected a decimal number\n"),
            (["batch", "0"], "batch: command 1 has no tokens\n"),
            (["batch", "1", "config", "debug_output", "2", "config"], "batch: command 2 has the count 'debug_output', expected a decimal number\n"),
        ] as [([String], String)])
        func aMalformedBatchIsRefusedWhole(_ row: ([String], String))
        {
            DaemonFixture.reset()
            #expect(text(runRawBatch(row.0.map { Array($0.utf8) })) == "\u{07}" + row.1)
        }

        // NOTE: The check is a note for a batch: its commands are read when the batch runs, not by config --check.
        @Test func checkDoesNotCheckTheCommandsOfABatch()
        {
            DaemonFixture.reset()
            var message = rawMessage(BatchMessage.encode([["config", "window_gap", "x"]]))
            let check = checkMessage(&message)
            #expect(check.failures.isEmpty)
            #expect(check.notes == ["not checked: batch commands are checked when they run"])
        }
    }
}
