import ArgumentParser
import Testing
@testable import Yabai
import YabaiTestSupport

// NOTE: The command line of the process (YabaiOptions.swift). Parsing touches no global state, so these run in parallel.

@Suite
struct YabaiOptionsTests
{
    @Test("no options run the daemon")
    func noOptions() throws
    {
        let options = try YabaiOptions.parse([])
        #expect(options.action == nil)
        #expect(options.message.isEmpty)
        #expect(options.config == nil)
        #expect(!options.verbose)
        #expect(!options.version)
    }

    @Test("every action by its long name", arguments: YabaiOptions.Action.allCases)
    func action(_ action: YabaiOptions.Action) throws
    {
        #expect(try YabaiOptions.parse(["--\(action.rawValue)"]).action == action)
    }

    @Test("config and verbose, long, short and attached")
    func configAndVerbose() throws
    {
        for arguments in [["--config", "/tmp/rc", "--verbose"], ["-V", "-c", "/tmp/rc"], ["-Vc", "/tmp/rc"], ["--config=/tmp/rc", "-V"]] {
            let options = try YabaiOptions.parse(arguments)
            #expect(options.config == "/tmp/rc")
            #expect(options.verbose)
        }
    }

    @Test("version, long and short")
    func version() throws
    {
        #expect(try YabaiOptions.parse(["--version"]).version)
        #expect(try YabaiOptions.parse(["-v"]).version)
    }

    @Test("--message takes every argument after it")
    func message() throws
    {
        #expect(try YabaiOptions.parse(["--message", "window", "--focus", "-V"]).message == ["window", "--focus", "-V"])
        #expect(try YabaiOptions.parse(["--message=query", "--spaces"]).message == ["query", "--spaces"])
    }

    @Test("an action, a message and the version must be given alone")
    func exclusive()
    {
        for arguments in [["--load-sa", "--stop-service"], ["--start-service", "-V"], ["--install-service", "-c", "rc"],
                          ["--version", "--stop-service"], ["-v", "-V"], ["-V", "-m", "query", "--spaces"]] {
            #expect(throws: (any Error).self, "\(arguments)") { try YabaiOptions.parse(arguments) }
        }
    }

    @Test("unknown options and a missing config file fail")
    func invalid()
    {
        for arguments in [["--bogus"], ["-c"], ["--config"], ["start-service"]] {
            #expect(throws: (any Error).self, "\(arguments)") { try YabaiOptions.parse(arguments) }
        }
    }
}
