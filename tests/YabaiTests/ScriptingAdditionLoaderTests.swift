import Testing
import YabaiCore

@testable import Yabai

//
// NOTE: The built-in load of the scripting addition (ScriptingAdditionLoader.swift). The tests run headless, so a request
// is recorded and no process starts. The result handler only logs and notifies, and starts a queued run, which headless
// mode never queues.
//

extension DaemonState {
  @Suite
  @WM struct ScriptingAdditionLoaderTests {
    @Test func requestsAreRecordedInOrder() {
      DaemonFixture.reset()
      ScriptingAdditionLoader.shared.load(reason: "startup")
      ScriptingAdditionLoader.shared.load(reason: "dock_did_restart")
      #expect(Headless.drain().scriptingAdditionLoads == ["startup", "dock_did_restart"])
    }

    @Test func aFailedResultIsNotified() {
      DaemonFixture.reset()
      EventHandler.shared.scriptingAdditionLoaded(.failed("sudo: a password is required"))
      #expect(
        Headless.drain().notifications == [
          "scripting-addition: could not load (sudo: a password is required); see sudoers setup in the man page"
        ])
    }

    @Test func aLoadedResultIsNotNotified() {
      DaemonFixture.reset()
      EventHandler.shared.scriptingAdditionLoaded(.loaded)
      #expect(Headless.drain().notifications.isEmpty)
    }
  }
}
