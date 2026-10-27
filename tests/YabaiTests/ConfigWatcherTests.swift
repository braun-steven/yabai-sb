import Foundation
import Synchronization
import Testing
import YabaiCore

@testable import Yabai

//
// NOTE: The change of the daemon's yabai.toml (ConfigWatcher.fileChanged, the `.configFileChanged` event). The shared
// headless watch skips directory sources; lifecycle tests inject a source and virtual scheduler. A failed check notifies,
// which headless mode records (Headless.notifications). The suite is DaemonState.
//

/// Writes `text` to a new yabai.toml in the temporary directory and returns its path; the caller removes it.
private func writeWatchedFile(_ text: String) throws -> String {
  let path = FileManager.default.temporaryDirectory.appendingPathComponent(
    "yabai-watch-\(UUID().uuidString).toml"
  ).path
  try text.write(toFile: path, atomically: true, encoding: .utf8)
  return path
}

private struct ConfigWatchSchedule: Equatable, Sendable {
  let delay: Duration
  let key: EventLoop.DelayedEventKey
}

/// A fake directory source for lifecycle tests: it records the watches it opens and cancels, and the delayed changes the
/// watcher posts. Superseding a keyed delayed event is EventLoop's job (DelayedQueueTests), so nothing here delivers them.
private final class ConfigWatcherTestDriver: @unchecked Sendable {
  private struct Watch: Sendable {
    let path: String
    let onEvent: @Sendable () -> Void
    var isCancelled = false
  }

  private struct State: Sendable {
    var watches: [Int: Watch] = [:]
    var nextWatchID = 0
    var openedPaths: [String] = []
    var cancelledPaths: [String] = []
    var schedules: [ConfigWatchSchedule] = []
  }

  private let state = Mutex(State())

  @WM func makeWatcher(fileDriver: ConfigWatcherTestDriver = ConfigWatcherTestDriver())
    -> ConfigWatcher
  {
    ConfigWatcher(
      allowsWatchingInHeadless: true,
      watchDirectory: { [self] path, onEvent in open(path, onEvent: onEvent) },
      postDelayedChange: { [self] delay, key in schedule(delay: delay, key: key) },
      watchFile: { path, onEvent in fileDriver.open(path, onEvent: onEvent) })
  }

  var activePaths: [String] {
    state.withLock { current in
      current.watches.values.filter { !$0.isCancelled }.map(\.path).sorted()
    }
  }

  var openedPaths: [String] {
    state.withLock { $0.openedPaths }
  }

  var cancelledPaths: [String] {
    state.withLock { $0.cancelledPaths }
  }

  var schedules: [ConfigWatchSchedule] {
    state.withLock { $0.schedules }
  }

  func open(_ path: String, onEvent: @escaping @Sendable () -> Void)
    -> ConfigWatchRegistration?
  {
    guard let identity = ConfigWatchDirectoryIdentity(at: path) else { return nil }
    let id = state.withLock { current in
      let id = current.nextWatchID
      current.nextWatchID += 1
      current.openedPaths.append(path)
      current.watches[id] = Watch(path: path, onEvent: onEvent)
      return id
    }
    return ConfigWatchRegistration(identity: identity) { [weak self] in self?.cancel(id: id) }
  }

  func schedule(delay: Duration, key: EventLoop.DelayedEventKey) {
    state.withLock { $0.schedules.append(ConfigWatchSchedule(delay: delay, key: key)) }
  }

  func emitEvents(in directory: String) {
    let handlers = state.withLock { current in
      current.watches.values
        .filter { !$0.isCancelled && $0.path == directory }
        .map(\.onEvent)
    }
    for handler in handlers {
      handler()
    }
  }

  private func cancel(id: Int) {
    state.withLock { current in
      guard var watch = current.watches[id], !watch.isCancelled else { return }
      watch.isCancelled = true
      current.watches[id] = watch
      current.cancelledPaths.append(watch.path)
    }
  }
}

extension DaemonState {
  @Suite
  @WM struct ConfigWatcherTests {
    @Test func symlinkTargetInPlaceWriteAndReplacementReopenTheFileWatch() throws {
      DaemonFixture.reset()
      let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("yabai-watch-\(UUID().uuidString)", isDirectory: true)
      let links = root.appendingPathComponent("links")
      let targets = root.appendingPathComponent("targets")
      try FileManager.default.createDirectory(at: links, withIntermediateDirectories: true)
      try FileManager.default.createDirectory(at: targets, withIntermediateDirectories: true)
      defer { try? FileManager.default.removeItem(at: root) }
      let link = links.appendingPathComponent("yabai.toml")
      let target = targets.appendingPathComponent("yabai.toml")
      let initial = "[config]\nwindow_gap = 11\n"
      try initial.write(to: target, atomically: true, encoding: .utf8)
      try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
      ConfigLoader.shared.filePath = link.path
      ConfigLoader.shared.lastContents = Array(initial.utf8)
      let driver = ConfigWatcherTestDriver()
      let fileDriver = ConfigWatcherTestDriver()
      let watcher = driver.makeWatcher(fileDriver: fileDriver)
      defer { watcher.stop() }
      watcher.sync()
      #expect(fileDriver.activePaths == [link.path])

      try "[config]\nwindow_gap = 12\n".write(to: target, atomically: false, encoding: .utf8)
      fileDriver.emitEvents(in: link.path)
      #expect(
        driver.schedules.last == ConfigWatchSchedule(delay: .milliseconds(200), key: .configReload))
      watcher.fileChanged()
      #expect(Golden.run("config window_gap") == Array("12\n".utf8))
      #expect(fileDriver.openedPaths.count == 1)

      try "[config]\nwindow_gap = 13\n".write(to: target, atomically: true, encoding: .utf8)
      watcher.fileChanged()
      #expect(Golden.run("config window_gap") == Array("13\n".utf8))
      #expect(fileDriver.cancelledPaths == [link.path])
      #expect(fileDriver.openedPaths == [link.path, link.path])
    }
    @Test func changedFileIsApplied() async throws {
      DaemonFixture.reset()
      let path = try writeWatchedFile("[config]\nwindow_gap = 12\n")
      defer { try? FileManager.default.removeItem(atPath: path) }
      ConfigLoader.shared.filePath = path
      _ = Headless.drain()

      await EventHandler.shared.handle(.configFileChanged)

      #expect(Golden.run("config window_gap") == Array("12\n".utf8))
      #expect(ConfigLoader.shared.lastContents == Array("[config]\nwindow_gap = 12\n".utf8))
      #expect(Headless.drain().notifications.isEmpty)
    }

    @Test func unchangedContentsApplyNothing() async throws {
      DaemonFixture.reset()
      let text = "[config]\nwindow_gap = 12\n"
      let path = try writeWatchedFile(text)
      defer { try? FileManager.default.removeItem(atPath: path) }
      ConfigLoader.shared.filePath = path
      ConfigLoader.shared.lastContents = Array(text.utf8)
      #expect(Golden.run("config window_gap 5") == [])

      await EventHandler.shared.handle(.configFileChanged)

      #expect(Golden.run("config window_gap") == Array("5\n".utf8))
    }

    @Test func autoReloadOffStopsTheWatchAndAppliesNothing() async throws {
      DaemonFixture.reset()
      let path = try writeWatchedFile(
        "[daemon]\nauto_reload = false\n\n[config]\nwindow_gap = 12\n")
      defer { try? FileManager.default.removeItem(atPath: path) }
      // The first load sets auto_reload off in the applied document: the watch is off from then on.
      ConfigLoader.shared.filePath = path
      #expect(Golden.run("config --reload \(path)") == Array("reloaded \(path): 1 changes\n".utf8))
      #expect(ConfigLoader.shared.autoReload == false)
      #expect(Golden.run("config window_gap 5") == [])
      try "[config]\nwindow_gap = 14\n".write(toFile: path, atomically: true, encoding: .utf8)

      await EventHandler.shared.handle(.configFileChanged)

      #expect(Golden.run("config window_gap") == Array("5\n".utf8))
    }

    @Test func failedCheckKeepsTheRunningConfigAndNotifies() async throws {
      DaemonFixture.reset()
      let path = try writeWatchedFile("[config]\nwindow_gap = \"x\"\n")
      defer { try? FileManager.default.removeItem(atPath: path) }
      ConfigLoader.shared.filePath = path
      #expect(Golden.run("config window_gap 5") == [])
      _ = Headless.drain()

      await EventHandler.shared.handle(.configFileChanged)

      #expect(Golden.run("config window_gap") == Array("5\n".utf8))
      #expect(
        Headless.drain().notifications
          == ["configuration: \(path) has 1 errors; kept the running config.."])
      #expect(ConfigLoader.shared.lastContents == Array("[config]\nwindow_gap = \"x\"\n".utf8))
    }

    @Test func fixingTheFileAppliesIt() async throws {
      DaemonFixture.reset()
      let path = try writeWatchedFile("[config]\nwindow_gap = \"x\"\n")
      defer { try? FileManager.default.removeItem(atPath: path) }
      ConfigLoader.shared.filePath = path
      #expect(Golden.run("config window_gap 5") == [])
      await EventHandler.shared.handle(.configFileChanged)
      #expect(Golden.run("config window_gap") == Array("5\n".utf8))

      try "[config]\nwindow_gap = 9\n".write(toFile: path, atomically: true, encoding: .utf8)
      await EventHandler.shared.handle(.configFileChanged)

      #expect(Golden.run("config window_gap") == Array("9\n".utf8))
    }

    @Test func missingFileChangesNothing() async {
      DaemonFixture.reset()
      ConfigLoader.shared.filePath = "/nonexistent/yabai-watch/yabai.toml"
      #expect(Golden.run("config window_gap 5") == [])
      _ = Headless.drain()

      await EventHandler.shared.handle(.configFileChanged)

      #expect(Golden.run("config window_gap") == Array("5\n".utf8))
      #expect(Headless.drain().notifications.isEmpty)
    }

    @Test func reloadOfAnotherFileKeepsTheWatchedContents() throws {
      DaemonFixture.reset()
      let path = try writeWatchedFile("[config]\nwindow_gap = 12\n")
      let other = try writeWatchedFile("[config]\nwindow_gap = 13\n")
      defer {
        try? FileManager.default.removeItem(atPath: path)
        try? FileManager.default.removeItem(atPath: other)
      }
      ConfigLoader.shared.filePath = path
      ConfigLoader.shared.lastContents = Array("[config]\nwindow_gap = 12\n".utf8)

      #expect(
        Golden.run("config --reload \(other)") == Array("reloaded \(other): 1 changes\n".utf8))

      #expect(ConfigLoader.shared.lastContents == Array("[config]\nwindow_gap = 12\n".utf8))
    }

    @Test func atomicReplacementPostsKeyedDebouncedChangesAndAppliesTheLatestContents() throws {
      DaemonFixture.reset()
      let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("yabai-watch-\(UUID().uuidString)", isDirectory: true)
      try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
      defer { try? FileManager.default.removeItem(at: directory) }

      let path = directory.appendingPathComponent("yabai.toml").path
      let initial = "[config]\nwindow_gap = 11\n"
      let replacement = "[config]\nwindow_gap = 14\n"
      try initial.write(toFile: path, atomically: true, encoding: .utf8)
      ConfigLoader.shared.filePath = path
      ConfigLoader.shared.lastContents = Array(initial.utf8)
      _ = Headless.drain()

      let driver = ConfigWatcherTestDriver()
      let watcher = driver.makeWatcher()
      defer { watcher.stop() }
      watcher.sync()
      #expect(driver.activePaths == [directory.path])

      // Foundation writes atomically by replacing the directory entry with a newly written file.
      try replacement.write(toFile: path, atomically: true, encoding: .utf8)
      driver.emitEvents(in: directory.path)
      driver.emitEvents(in: directory.path)
      driver.emitEvents(in: directory.path)

      // Each event posts the debounced change under one key, so the event loop keeps only the last of the burst.
      #expect(
        driver.schedules
          == Array(
            repeating: ConfigWatchSchedule(delay: .milliseconds(200), key: .configReload),
            count: 3))
      watcher.fileChanged()

      #expect(Golden.run("config window_gap") == Array("14\n".utf8))
      #expect(ConfigLoader.shared.lastContents == Array(replacement.utf8))
      #expect(Headless.drain().configEntries.map(\.arguments) == [["config", "window_gap", "14"]])
    }

    @Test func retargetedSymlinkMovesTheTargetWatchAndReloadsTheNewTarget() throws {
      DaemonFixture.reset()
      let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("yabai-watch-\(UUID().uuidString)", isDirectory: true)
      let linkDirectory = root.appendingPathComponent("config", isDirectory: true)
      let firstDirectory = root.appendingPathComponent("first", isDirectory: true)
      let secondDirectory = root.appendingPathComponent("second", isDirectory: true)
      for directory in [linkDirectory, firstDirectory, secondDirectory] {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
      }
      defer { try? FileManager.default.removeItem(at: root) }

      let firstTarget = firstDirectory.appendingPathComponent("yabai.toml")
      let secondTarget = secondDirectory.appendingPathComponent("yabai.toml")
      let link = linkDirectory.appendingPathComponent("yabai.toml")
      let firstText = "[config]\nwindow_gap = 12\n"
      let secondText = "[config]\nwindow_gap = 19\n"
      try firstText.write(to: firstTarget, atomically: true, encoding: .utf8)
      try secondText.write(to: secondTarget, atomically: true, encoding: .utf8)
      let firstResolvedDirectory = ConfigWatch.directory(of: resolvedPath(firstTarget.path))
      let secondResolvedDirectory = ConfigWatch.directory(of: resolvedPath(secondTarget.path))
      try FileManager.default.createSymbolicLink(
        atPath: link.path, withDestinationPath: firstTarget.path)
      ConfigLoader.shared.filePath = link.path
      ConfigLoader.shared.lastContents = Array(firstText.utf8)
      _ = Headless.drain()

      let driver = ConfigWatcherTestDriver()
      let watcher = driver.makeWatcher()
      defer { watcher.stop() }
      watcher.sync()
      #expect(driver.activePaths == [firstResolvedDirectory, linkDirectory.path].sorted())

      try FileManager.default.removeItem(at: link)
      try FileManager.default.createSymbolicLink(
        atPath: link.path, withDestinationPath: secondTarget.path)
      driver.emitEvents(in: linkDirectory.path)
      watcher.fileChanged()

      #expect(driver.activePaths == [secondResolvedDirectory, linkDirectory.path].sorted())
      #expect(driver.cancelledPaths == [firstResolvedDirectory])
      #expect(
        driver.openedPaths == [linkDirectory.path, firstResolvedDirectory, secondResolvedDirectory])
      #expect(Golden.run("config window_gap") == Array("19\n".utf8))
      #expect(ConfigLoader.shared.lastContents == Array(secondText.utf8))
    }

    @Test func disablingAutoReloadCancelsTheWatchAndIgnoresLaterChanges() throws {
      DaemonFixture.reset()
      let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("yabai-watch-\(UUID().uuidString)", isDirectory: true)
      try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
      defer { try? FileManager.default.removeItem(at: directory) }

      let path = directory.appendingPathComponent("yabai.toml").path
      let initial = "[config]\nwindow_gap = 11\n"
      try initial.write(toFile: path, atomically: true, encoding: .utf8)
      ConfigLoader.shared.filePath = path
      ConfigLoader.shared.lastContents = Array(initial.utf8)
      #expect(Golden.run("config window_gap 5") == [])
      _ = Headless.drain()

      let driver = ConfigWatcherTestDriver()
      let watcher = driver.makeWatcher()
      defer { watcher.stop() }
      watcher.sync()
      #expect(driver.activePaths == [directory.path])

      var applied = ConfigDocument()
      applied.daemon.autoReload = false
      ConfigLoader.shared.applied = applied
      watcher.sync()
      #expect(driver.activePaths.isEmpty)
      #expect(driver.cancelledPaths == [directory.path])

      try "[config]\nwindow_gap = 19\n".write(toFile: path, atomically: true, encoding: .utf8)
      driver.emitEvents(in: directory.path)
      watcher.fileChanged()

      #expect(driver.schedules.isEmpty)
      #expect(Golden.run("config window_gap") == Array("5\n".utf8))
      #expect(ConfigLoader.shared.lastContents == Array(initial.utf8))
    }

    @Test func missingDirectorySchedulesRetryAndOpensAfterItAppears() throws {
      DaemonFixture.reset()
      let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("yabai-watch-\(UUID().uuidString)", isDirectory: true)
      try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
      defer { try? FileManager.default.removeItem(at: root) }

      let directory = root.appendingPathComponent("created-later", isDirectory: true)
      let path = directory.appendingPathComponent("yabai.toml").path
      ConfigLoader.shared.filePath = path

      let driver = ConfigWatcherTestDriver()
      let watcher = driver.makeWatcher()
      defer { watcher.stop() }
      watcher.sync()

      #expect(driver.activePaths.isEmpty)
      #expect(
        driver.schedules == [
          ConfigWatchSchedule(delay: .seconds(5), key: .configReload)
        ])

      // The retry is the change event: by then the directory and the file exist.
      try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
      try "[config]\nwindow_gap = 17\n".write(toFile: path, atomically: true, encoding: .utf8)
      watcher.fileChanged()

      #expect(driver.activePaths == [directory.path])
      #expect(driver.openedPaths == [directory.path])
      #expect(driver.schedules.count == 1)
      #expect(Golden.run("config window_gap") == Array("17\n".utf8))
    }

    @Test func replacementDirectoryAtTheSamePathReopensItsWatch() throws {
      DaemonFixture.reset()
      let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("yabai-watch-\(UUID().uuidString)", isDirectory: true)
      let directory = root.appendingPathComponent("config", isDirectory: true)
      let movedDirectory = root.appendingPathComponent("old-config", isDirectory: true)
      try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
      defer { try? FileManager.default.removeItem(at: root) }

      let path = directory.appendingPathComponent("yabai.toml").path
      let initial = "[config]\nwindow_gap = 11\n"
      let replacement = "[config]\nwindow_gap = 18\n"
      try initial.write(toFile: path, atomically: true, encoding: .utf8)
      ConfigLoader.shared.filePath = path
      ConfigLoader.shared.lastContents = Array(initial.utf8)
      _ = Headless.drain()

      let driver = ConfigWatcherTestDriver()
      let watcher = driver.makeWatcher()
      defer { watcher.stop() }
      watcher.sync()
      let originalIdentity = ConfigWatchDirectoryIdentity(at: directory.path)
      #expect(driver.activePaths == [directory.path])

      try FileManager.default.moveItem(at: directory, to: movedDirectory)
      try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
      try replacement.write(toFile: path, atomically: true, encoding: .utf8)
      let replacementIdentity = ConfigWatchDirectoryIdentity(at: directory.path)
      #expect(originalIdentity != replacementIdentity)

      watcher.sync()
      #expect(driver.activePaths == [directory.path])
      #expect(driver.cancelledPaths == [directory.path])
      #expect(driver.openedPaths == [directory.path, directory.path])

      driver.emitEvents(in: directory.path)
      watcher.fileChanged()
      #expect(Golden.run("config window_gap") == Array("18\n".utf8))
      #expect(ConfigLoader.shared.lastContents == Array(replacement.utf8))
    }
  }
}
