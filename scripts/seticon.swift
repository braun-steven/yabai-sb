// Sets the Finder icon of a file, e.g. the yabai binary, so that the Accessibility list in System Settings shows it.
// Usage: swift scripts/seticon.swift <image> <file>
import AppKit

let arguments = CommandLine.arguments
guard arguments.count == 3, let image = NSImage(contentsOfFile: arguments[1]) else {
  FileHandle.standardError.write(Data("usage: seticon.swift <image> <file>\n".utf8))
  exit(1)
}
guard NSWorkspace.shared.setIcon(image, forFile: arguments[2], options: []) else {
  FileHandle.standardError.write(Data("could not set the icon of \(arguments[2])\n".utf8))
  exit(1)
}
