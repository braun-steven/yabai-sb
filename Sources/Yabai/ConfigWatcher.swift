import Dispatch
import Foundation
import Logging
import YabaiCore

//
// NOTE: The watch of the daemon's yabai.toml (`[daemon] auto_reload`). It watches directories, not the file, so an editor
// that saves by writing a new file and renaming it is seen too. Two directories are watched (ConfigWatch.directories): the
// file's directory as given, which sees a symlink being replaced, and, when the file is a symlink into another directory,
// the directory of its target, which sees an edit of the target. sync recomputes both on each call, so a re-pointed link
// moves the second watch, and it reopens only the directories whose identity (device and inode) changed. Each event of a
// directory posts `.configFileChanged`
// 200 ms later under the `.configReload` key, so a burst of writes is one reload. fileChanged reads the file, decides with
// ConfigWatch.action whether its text differs from the last load or attempt, and applies it through reloadConfig, the same
// path as `config --reload`. A failed check logs every line, notifies and keeps the running config.
//
// The directories' events arrive on the private serial queue of the watch, which only posts events. All the state of the watch
// is on @WM. A directory that cannot be opened (it does not exist yet, or was removed) is retried through a delayed event.
// The watch is off while the applied document sets `auto_reload = false`, and on when no document is applied (the startup
// file was invalid or missing, so fixing it applies it; ConfigLoader.autoReload).
//
// In headless mode (the tests) the watch never opens a file: the tests call fileChanged, which does the same work.
//

/// The queue of the directory events. It only posts events, and it closes the descriptor of a cancelled watch.
private let configWatchQueue = DispatchQueue(label: "yabai.config.watch")

/// The device and inode of a directory: a directory that was removed and created again has another one.
private struct DirectoryIdentity: Equatable {
  let device: dev_t
  let inode: ino_t
}

/// The identity of the directory at `path`, or nil when it does not exist.
private func directoryIdentity(at path: String) -> DirectoryIdentity? {
  var info = stat()
  guard stat(path, &info) == 0 else { return nil }
  return DirectoryIdentity(device: info.st_dev, inode: info.st_ino)
}

/// A directory the watch is open on.
private struct OpenWatch {
  let path: String
  let identity: DirectoryIdentity
  let source: any DispatchSourceFileSystemObject
}

/// How long a directory that cannot be opened waits before it is tried again.
private let configWatchRetry: Duration = .seconds(5)

/// How long after the last event of a directory the file is read, so a burst of writes is one reload.
private let configWatchDebounce: Duration = .milliseconds(200)

/// Watches the daemon's yabai.toml and applies its changes (see the NOTE above).
@WM final class ConfigWatcher {
  static let shared = ConfigWatcher()

  /// The open watches: one per directory of ConfigWatch.directories, at most two.
  private var watches: [OpenWatch] = []

  /// Opens the watches on the directories of the daemon's file when auto-reload is on, and closes them when it is off. It
  /// also reopens a directory after it was removed or replaced, and moves the second watch when a symlink is re-pointed.
  /// Called after each load and each event; a directory that cannot be opened is retried later.
  func sync() {
    guard !Headless.isEnabled else { return }

    guard ConfigLoader.shared.autoReload, let path = ConfigLoader.shared.filePath else {
      stop()
      return
    }

    let wanted = ConfigWatch.directories(path: path, resolved: resolvedPath(path))

    // Keep the open watches whose directory is still wanted and still the same directory; close the others.
    var kept: [OpenWatch] = []
    for watch in watches {
      if wanted.contains(watch.path), directoryIdentity(at: watch.path) == watch.identity {
        kept.append(watch)
      } else {
        watch.source.cancel()
      }
    }

    var retry = false
    for directoryPath in wanted where !kept.contains(where: { $0.path == directoryPath }) {
      // Two spellings of one directory (a relative path and its target) share one watch.
      guard let identity = directoryIdentity(at: directoryPath) else {
        Logger.daemon.debug("config watch: \(directoryPath) does not exist; retrying")
        retry = true
        continue
      }
      if kept.contains(where: { $0.identity == identity }) { continue }

      if let opened = openWatch(directoryPath) {
        kept.append(opened)
      } else {
        retry = true
      }
    }

    watches = kept
    if retry {
      EventLoop.post(.configFileChanged, after: configWatchRetry, key: .configReload)
    }
  }

  /// Closes the watches, if any are open. The cancel handlers close the descriptors.
  func stop() {
    for watch in watches {
      watch.source.cancel()
    }
    watches = []
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

    switch reloadConfig(configFileCheck(path: path, source: text)) {
    case .failed(let report):
      for line in report.text.split(separator: "\n") {
        Logger.daemon.warning("config watch: \(line)")
      }
      notify("configuration", "\(path) has \(report.failures) errors; kept the running config..")
    case .reloaded(let path, let result):
      Logger.daemon.notice("config watch: reloaded \(path): \(result.changes) changes")
      if result.failures > 0 {
        notify("configuration", "\(result.failures) settings of \(path) did not apply..")
      }
    }
  }

  /// Opens a directory and watches its writes, renames and deletes. Nil when it cannot be opened.
  private func openWatch(_ directoryPath: String) -> OpenWatch? {
    let descriptor = open(directoryPath, O_EVTONLY)
    guard descriptor >= 0 else {
      Logger.daemon.debug("config watch: cannot open \(directoryPath); retrying")
      return nil
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

    return OpenWatch(
      path: directoryPath,
      identity: DirectoryIdentity(device: info.st_dev, inode: info.st_ino),
      source: source)
  }
}

/// The text of the watched file, or nil when it cannot be read (it does not exist, or is not a regular file).
private func readWatchedText(_ path: String) -> String? {
  guard fileExists(path), let data = FileManager.default.contents(atPath: path) else { return nil }
  return String(decoding: data, as: UTF8.self)
}
