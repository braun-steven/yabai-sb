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
    "the failure reason is the last stderr line, else the exit status, else the kind of failure",
    arguments: [
      (ScriptingAdditionLoadExit.exited(0), "", nil),
      (ScriptingAdditionLoadExit.exited(0), "warning\n", nil),
      (
        ScriptingAdditionLoadExit.exited(1), "sudo: a password is required\n",
        "sudo: a password is required"
      ),
      (ScriptingAdditionLoadExit.exited(1), "first\n\n  second line  \n \n", "second line"),
      (ScriptingAdditionLoadExit.exited(1), "first\r\nlast\r\n", "last"),
      (ScriptingAdditionLoadExit.exited(1), "  \n", "exit status 1"),
      (ScriptingAdditionLoadExit.exited(2), "", "exit status 2"),
      (ScriptingAdditionLoadExit.signaled(9), "", "killed by signal 9"),
      (ScriptingAdditionLoadExit.timedOut, "", "timed out after 30 s"),
      (ScriptingAdditionLoadExit.notStarted, "", "could not start /usr/bin/sudo"),
    ] as [(ScriptingAdditionLoadExit, String, String?)])
  func failureReason(exit: ScriptingAdditionLoadExit, stderr: String, expected: String?) {
    #expect(ScriptingAdditionLoad.failureReason(exit, stderr: stderr) == expected)
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
