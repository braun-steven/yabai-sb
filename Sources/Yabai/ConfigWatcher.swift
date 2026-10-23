import Dispatch
import Foundation
import Logging
import YabaiCore

//
// NOTE: The watch of the daemon's yabai.toml (`[daemon] auto_reload`). It watches the file's directory, not the file, so an
// editor that saves by writing a new file and renaming it is seen too. Each event of the directory posts `.configFileChanged`
// 200 ms later under the `.configReload` key, so a burst of writes is one reload. fileChanged reads the file, decides with
// ConfigWatch.action whether its text differs from the last load or attempt, and applies it through reloadConfig, the same
// path as `config --reload`. A failed check logs every line, notifies and keeps the running config.
//
// The directory's events arrive on the private serial queue of the watch, which only posts events. All the state of the watch
// is on @WM. A directory that cannot be opened (it does not exist yet, or was removed) is retried through a delayed event.
// The watch is off while the applied document sets `auto_reload = false`, and on when no document is applied (the startup
// file was invalid or missing, so fixing it applies it; ConfigLoader.autoReload).
//
// In headless mode (the tests) the watch never opens a file: the tests call fileChanged, which does the same work.
//

/// The queue of the directory events. It only posts events, and it closes the descriptor of a cancelled watch.
private let configWatchQueue = DispatchQueue(label: "yabai.config.watch")

/// The directory a watch is open on, with its identity: a directory that was removed and created again is opened again.
private struct WatchedDirectory {
  let path: String
  let device: dev_t
  let inode: ino_t
}

/// How long a directory that cannot be opened waits before it is tried again.
private let configWatchRetry: Duration = .seconds(5)

/// How long after the last event of the directory the file is read, so a burst of writes is one reload.
private let configWatchDebounce: Duration = .milliseconds(200)

/// Watches the daemon's yabai.toml and applies its changes (see the NOTE above).
@WM final class ConfigWatcher {
  static let shared = ConfigWatcher()

  private var source: (any DispatchSourceFileSystemObject)?
  private var directory: WatchedDirectory?

  /// Opens the watch on the directory of the daemon's file when auto-reload is on, and closes it when it is off. It also
  /// opens a directory again after it was removed or replaced. Called after each load and each event; a directory that
  /// cannot be opened is retried later.
  func sync() {
    guard !Headless.isEnabled else { return }

    guard ConfigLoader.shared.autoReload, let path = ConfigLoader.shared.filePath else {
      stop()
      return
    }

    let directoryPath = ConfigWatch.directory(of: path)
    if let watched = directory, watched.path == directoryPath,
      let current = identity(of: directoryPath), current == (watched.device, watched.inode)
    {
      return
    }

    stop()
    startWatch(directoryPath)
  }

  /// Closes the watch, if one is open. The cancel handler closes the descriptor.
  func stop() {
    source?.cancel()
    source = nil
    directory = nil
  }

  /// The event of the watched file: the debounced directory event, or a retry of sync. Applies the file when its text differs
  /// from the last load or attempt (ConfigWatch.action).
  func fileChanged() {
    sync()

    guard let path = ConfigLoader.shared.filePath else { return }
    let text = readWatchedText(path)
    let action = ConfigWatch.action(
      autoReload: ConfigLoader.shared.autoReload,
      loaded: ConfigLoader.shared.lastContents,
      current: text.map { Array($0.utf8) })
    switch action {
    case .stopped, .unchanged:
      return
    case .missing:
      Logger.daemon.debug("config watch: \(path) does not exist; the running config is kept")
      return
    case .reload:
      break
    }
    guard let text else { return }

    switch reloadConfig(path: path, check: configFileCheck(path: path, source: text)) {
    case .failed(let report):
      for line in report.text.split(separator: "\n") {
        Logger.daemon.warning("config watch: \(line)")
      }
      notify("configuration", "\(path) has \(report.failures) errors; kept the running config..")
    case .reloaded(let path, let result):
      Logger.daemon.notice("config watch: reloaded \(path): \(result.changes) changes")
    }
  }

  /// Opens the directory and watches its writes, renames and deletes. A directory that cannot be opened is retried.
  private func startWatch(_ directoryPath: String) {
    let descriptor = open(directoryPath, O_EVTONLY)
    guard descriptor >= 0 else {
      Logger.daemon.debug("config watch: cannot open \(directoryPath); retrying")
      EventLoop.post(.configFileChanged, after: configWatchRetry, key: .configReload)
      return
    }

    var info = stat()
    fstat(descriptor, &info)

    let source = DispatchSource.makeFileSystemObjectSource(
      fileDescriptor: descriptor, eventMask: [.write, .rename, .delete], queue: configWatchQueue)
    source.setEventHandler {
      EventLoop.post(.configFileChanged, after: configWatchDebounce, key: .configReload)
    }
    source.setCancelHandler { close(descriptor) }
    source.resume()

    self.source = source
    directory = WatchedDirectory(path: directoryPath, device: info.st_dev, inode: info.st_ino)
  }

  /// The device and inode of a path, or nil when it does not exist.
  private func identity(of path: String) -> (dev_t, ino_t)? {
    var info = stat()
    guard stat(path, &info) == 0 else { return nil }
    return (info.st_dev, info.st_ino)
  }
}

/// The text of the watched file, or nil when it cannot be read (it does not exist).
private func readWatchedText(_ path: String) -> String? {
  guard let data = FileManager.default.contents(atPath: path) else { return nil }
  return String(decoding: data, as: UTF8.self)
}
