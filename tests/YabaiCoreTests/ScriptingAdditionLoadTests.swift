import Testing

@testable import YabaiCore

@Suite("scripting addition load")
struct ScriptingAdditionLoadTests {
  @Test func argvRunsTheExecutableWithSudoAndNoPrompt() {
    #expect(
      ScriptingAdditionLoad.arguments(executable: "/opt/yabai/bin/yabai")
        == ["/usr/bin/sudo", "-n", "/opt/yabai/bin/yabai", "--load-sa"])
  }

  @Test(
    "the failure reason is the last stderr line; a run without one leaves it to the payload, a timeout has its own",
    arguments: [
      (ScriptingAdditionLoadExit.ended, "", nil),
      (ScriptingAdditionLoadExit.ended, "warning\n", "warning"),
      (
        ScriptingAdditionLoadExit.ended, "sudo: a password is required\n",
        "sudo: a password is required"
      ),
      (ScriptingAdditionLoadExit.ended, "first\n\n  second line  \n \n", "second line"),
      (ScriptingAdditionLoadExit.ended, "first\r\nlast\r\n", "last"),
      (ScriptingAdditionLoadExit.ended, "  \n", nil),
      (ScriptingAdditionLoadExit.timedOut, "", "timed out after 30 s"),
      (
        ScriptingAdditionLoadExit.notStarted("posix_spawn failed"), "",
        "could not start /usr/bin/sudo: posix_spawn failed"
      ),
    ] as [(ScriptingAdditionLoadExit, String, String?)])
  func failureReason(exit: ScriptingAdditionLoadExit, stderr: String, expected: String?) {
    #expect(ScriptingAdditionLoad.failureReason(exit, stderr: stderr) == expected)
  }

  @Test func theOutputTailKeepsTheLastBytes() {
    var tail = OutputTail(limit: 8)
    tail.append(Array("first\n".utf8))
    #expect(tail.text == "first\n")
    tail.append(Array("second\nlast\n".utf8))
    #expect(tail.text == "nd\nlast\n")
    #expect(ScriptingAdditionLoad.failureReason(.ended, stderr: tail.text) == "last")
  }

  @Test func theOutputTailReplacesACutCharacter() {
    var tail = OutputTail(limit: 3)
    tail.append(Array("\u{E9}ab".utf8))
    #expect(tail.text == "\u{FFFD}ab")
  }

  @Test func aRequestWithNoRunStartsOne() {
    var queue = ScriptingAdditionLoadQueue()
    #expect(queue.request() == .start)
    #expect(queue.isRunning)
    #expect(!queue.isPending)
    #expect(queue.finish() == .idle)
    #expect(!queue.isRunning)
  }

  @Test func requestsDuringARunMakeOneRunAfterIt() {
    var queue = ScriptingAdditionLoadQueue()
    #expect(queue.request() == .start)
    #expect(queue.request() == .queued)
    #expect(queue.request() == .queued)
    #expect(queue.isPending)
    #expect(queue.finish() == .start)
    #expect(queue.isRunning)
    #expect(!queue.isPending)
    #expect(queue.finish() == .idle)
    #expect(!queue.isRunning)
  }

  @Test func aRequestAfterTheRunsEndedStartsAgain() {
    var queue = ScriptingAdditionLoadQueue()
    #expect(queue.request() == .start)
    #expect(queue.finish() == .idle)
    #expect(queue.request() == .start)
    #expect(queue.finish() == .idle)
  }
}
