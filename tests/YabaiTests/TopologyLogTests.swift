import CoreGraphics
import Foundation
import Testing
import YabaiCore

@testable import Yabai

/// A new directory that the test removes.
private func withTemporaryDirectory(_ body: (String) throws -> Void) throws {
  let directory = NSTemporaryDirectory() + "yabai-topology-" + UUID().uuidString
  try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
  defer { try? FileManager.default.removeItem(atPath: directory) }
  try body(directory)
}

/// The text of a file, nil when it can not be read.
private func contents(_ path: String) -> String? {
  try? String(contentsOfFile: path, encoding: .utf8)
}

@Test func rotatingLogFileMovesTheFullFileAside() throws {
  try withTemporaryDirectory { directory in
    let path = directory + "/log"
    var file = RotatingLogFile(path: path, limit: 8)

    file.append("first 1\n")
    file.append("second\n")
    file.append("third\n")

    #expect(contents(path + ".1") == "first 1\n")
    #expect(contents(path) == "second\nthird\n")

    file.append("fourth\n")

    #expect(contents(path + ".1") == "second\nthird\n")
    #expect(contents(path) == "fourth\n")
  }
}

@Test func rotatingLogFileCountsTheSizeOfAnExistingFile() throws {
  try withTemporaryDirectory { directory in
    let path = directory + "/log"
    try "12345678\n".write(toFile: path, atomically: false, encoding: .utf8)

    var file = RotatingLogFile(path: path, limit: 8)
    file.append("new\n")

    #expect(contents(path + ".1") == "12345678\n")
    #expect(contents(path) == "new\n")
  }
}

@Test func rotatingLogFileLosesTheLineWhenItCanNotOpen() {
  var file = RotatingLogFile(path: "/nonexistent-directory/log", limit: 8)
  file.append("line\n")
}

@Test func topologyLogNamesTheDisplayFlags() {
  let rows: [(CGDisplayChangeSummaryFlags, String)] = [
    (.beginConfigurationFlag, "begin"),
    ([.addFlag, .enabledFlag], "add,enabled"),
    ([.movedFlag, .setMainFlag, .setModeFlag, .desktopShapeChangedFlag], "moved,main,mode,shape"),
    ([.removeFlag, .disabledFlag, .mirrorFlag, .unMirrorFlag], "remove,disabled,mirror,unmirror"),
    ([], ""),
  ]

  for (flags, text) in rows {
    #expect(TopologyLog.text(of: flags) == text)
  }
}

@Test func topologyLogWithoutBeginBuildsNoDetail() {
  func detail() -> String {
    Issue.record("the detail must not be built")
    return ""
  }

  TopologyLog.record("kind", detail())
}

@Test func topologySnapshotsFollowAChangeThenBecomePeriodic() {
  #expect(TopologySnapshotReason.settle.next.reason == .late)
  #expect(TopologySnapshotReason.late.next.reason == .periodic)
  #expect(TopologySnapshotReason.periodic.next.reason == .periodic)
  #expect(TopologySnapshotReason.start.next.reason == .periodic)
  #expect(TopologySnapshotReason.sleep.next.reason == .periodic)
}
