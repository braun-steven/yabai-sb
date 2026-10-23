import AppKit
import Foundation
import SortedCollections
import YabaiCore

//
// NOTE: space --save-layout. The tree of the acting space is written as a LayoutFile to <directory>/<name>.json. Each
// leaf gets the matcher of its window: the bundle id and name of its application, and the accessibility title, role and
// subrole that the window had when it was last read (Window.ax).
//

/// The directory of the layout files, from the environment of the daemon (see LayoutStore.directory).
@WM func layoutDirectory() -> String? {
  LayoutStore.directory(
    xdgConfigHome: getenv("XDG_CONFIG_HOME").map { String(cString: $0) },
    home: getenv("HOME").map { String(cString: $0) })
}

/// Writes the tree of `sid` as the layout `name` into `directory`, and returns the path of the file. The directory is
/// created when it is missing; the file is written atomically, so a reader never sees a partial one.
@WM func saveSpaceLayout(name: String, on sid: SpaceID, directory: String) throws(CommandError)
  -> String
{
  guard LayoutStore.isValidName(name) else {
    throw SpaceCommand.unknownValue(.saveLayout, Token(name), expected: LayoutStore.nameDescription)
  }
  guard let view = SpaceManager.shared.views[sid], let tree = view.tree else {
    throw CommandError("cannot save the layout of a non-managed space.\n")
  }

  let file = LayoutFile(snapshot: tree.snapshot) { windowID in layoutMatcher(for: windowID) }
  let path = LayoutStore.path(name: name, directory: directory)
  do {
    try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
    try LayoutFile.encode(file).write(to: URL(filePath: path), options: .atomic)
  } catch {
    throw CommandError("could not write layout to '\(path)'.\n")
  }
  return path
}

/// The matcher of a window, or nil when the window manager does not know it. space --restore-layout matches the same facts.
@WM func layoutMatcher(for windowID: WindowID) -> LayoutMatcher? {
  guard let window = WindowManager.shared.window(for: windowID),
    let application = window.application
  else { return nil }

  return LayoutMatcher(
    bundleID: application.bundleID, app: application.name, title: window.ax.title,
    role: window.ax.role, subrole: window.ax.subrole)
}
