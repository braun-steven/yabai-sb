import AppKit
import CoreMedia
import ScreenCaptureKit
import Synchronization

// Real-world latency of the four things a user sees: a focus change, a window move (tiled swap), a space
// change and the border following them. Each sample spawns `yabai -m` like a hotkey daemon does and stops
// the clock when the window server (CGWindowList order, frames and on-screen state) and the screen
// (ScreenCaptureKit pixels at the border) show the result. The user's config is used as is.
// Compile: xcrun swiftc -O -swift-version 6 -parse-as-library realworld_perf.swift -o /tmp/yabai-realworld-perf
// Run outside the command sandbox, TextEdit, Script Editor and Calculator closed:
//   /tmp/yabai-realworld-perf [samples] [results.json]
// It opens Calculator on space 5, 2 TextEdit documents and 1 Script Editor document on space 4, quits
// the three apps afterwards and focuses the window that was focused before.

private func ticks() -> UInt64 { mach_absolute_time() }
private let msPerTick: Double = {
  var info = mach_timebase_info_data_t()
  mach_timebase_info(&info)
  return Double(info.numer) / Double(info.denom) / 1_000_000
}()
private func ms(_ from: UInt64, _ to: UInt64) -> Double { Double(to &- from) * msPerTick }

private struct BenchError: Error, CustomStringConvertible {
  let description: String
  init(_ description: String) { self.description = description }
}

private let yabai = FileManager.default.homeDirectoryForCurrentUser
  .appendingPathComponent(".local/bin/yabai").path

@discardableResult
private func shell(_ executable: String, _ args: [String], allowFailure: Bool = false) throws
  -> String
{
  let process = Process()
  process.executableURL = URL(fileURLWithPath: executable)
  process.arguments = args
  let output = Pipe()
  process.standardOutput = output
  process.standardError = output
  try process.run()
  let data = output.fileHandleForReading.readDataToEndOfFile()
  process.waitUntilExit()
  let text = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
  if process.terminationStatus != 0 && !allowFailure { throw BenchError("\(args): \(text)") }
  return text
}

@discardableResult
private func y(_ args: String..., allowFailure: Bool = false) throws -> String {
  try shell(yabai, ["-m"] + args, allowFailure: allowFailure)
}

private func osa(_ script: String) {
  _ = try? shell("/usr/bin/osascript", ["-e", script], allowFailure: true)
}

// The main task blocks on purpose: it drives one command at a time and polls the window server.
private func pause(_ seconds: Double) { usleep(useconds_t(seconds * 1_000_000)) }

private func json(_ text: String) -> Any? {
  try? JSONSerialization.jsonObject(with: Data(text.utf8))
}

private let errorLog = NSTemporaryDirectory() + "yabai-realworld-perf.err"

// Starts `yabai -m <args>` without waiting, so the window server can be watched while it runs.
// Its stderr goes to `errorLog`.
private func spawn(_ args: [String]) throws -> pid_t {
  var pid: pid_t = 0
  var actions: posix_spawn_file_actions_t?
  posix_spawn_file_actions_init(&actions)
  defer { posix_spawn_file_actions_destroy(&actions) }
  posix_spawn_file_actions_addopen(&actions, 1, "/dev/null", O_WRONLY, 0)
  posix_spawn_file_actions_addopen(&actions, 2, errorLog, O_WRONLY | O_CREAT | O_TRUNC, 0o600)
  let argv = ([yabai, "-m"] + args).map { strdup($0) } + [nil]
  defer { for arg in argv { free(arg) } }
  guard posix_spawn(&pid, yabai, &actions, nil, argv, environ) == 0 else {
    throw BenchError("cannot spawn yabai")
  }
  return pid
}

// MARK: window server observations

private func onScreenOrder(_ ids: Set<UInt32>) -> [UInt32] {
  let list =
    CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] ?? []
  return list.compactMap { $0[kCGWindowNumber as String] as? UInt32 }.filter(ids.contains)
}

private func bounds(_ id: UInt32) -> CGRect? {
  // The array holds the window number itself in place of a pointer, without retain callbacks.
  var values = [UnsafeRawPointer(bitPattern: UInt(id))]
  let ids = CFArrayCreate(nil, &values, 1, nil)
  guard let list = CGWindowListCreateDescriptionFromArray(ids) as? [[String: Any]],
    let info = list.first, let dict = info[kCGWindowBounds as String] as CFTypeRef?
  else { return nil }
  return CGRect(dictionaryRepresentation: dict as! CFDictionary)
}

private func isLocked() -> Bool {
  let session = CGSessionCopyCurrentDictionary() as? [String: Any]
  return session?["CGSSessionScreenIsLocked"] as? Bool == true
}

// MARK: border pixels

private struct PixelState {
  var colors: [[Double]] = []
  // The request whose first matching frame is recorded: start tick and the index of the active point.
  var request: (started: UInt64, active: Int)?
  var matched: UInt64?
}

// NOTE: Callbacks run on the capture queue; the mutex guards everything they share with the main task.
private final class PixelMonitor: NSObject, SCStreamOutput, @unchecked Sendable {
  let points: [CGPoint]
  let display: CGRect
  let state = Mutex(PixelState())
  // Calibrated colors of an active and a normal border; set before the first request.
  let palette = Mutex<(active: [Double], normal: [Double])>(([], []))

  init(points: [CGPoint], display: CGRect) {
    self.points = points
    self.display = display
  }

  func isActive(_ color: [Double]) -> Bool {
    let (active, normal) = palette.withLock { $0 }
    return distance(color, active) < distance(color, normal)
  }

  private func distance(_ a: [Double], _ b: [Double]) -> Double {
    zip(a, b).reduce(0) { $0 + ($1.0 - $1.1) * ($1.0 - $1.1) }
  }

  func stream(
    _ stream: SCStream, didOutputSampleBuffer buffer: CMSampleBuffer, of type: SCStreamOutputType
  ) {
    guard type == .screen, let pixels = CMSampleBufferGetImageBuffer(buffer) else { return }
    CVPixelBufferLockBaseAddress(pixels, .readOnly)
    defer { CVPixelBufferUnlockBaseAddress(pixels, .readOnly) }
    guard let base = CVPixelBufferGetBaseAddress(pixels) else { return }
    let width = CVPixelBufferGetWidth(pixels)
    let height = CVPixelBufferGetHeight(pixels)
    let stride = CVPixelBufferGetBytesPerRow(pixels)
    let bytes = base.assumingMemoryBound(to: UInt8.self)
    let colors = points.map { point -> [Double] in
      let x = min(width - 1, max(0, Int((point.x - display.minX) * Double(width) / display.width)))
      let y = min(
        height - 1, max(0, Int((point.y - display.minY) * Double(height) / display.height)))
      let offset = y * stride + x * 4
      return [Double(bytes[offset + 2]), Double(bytes[offset + 1]), Double(bytes[offset])]
    }
    let attachments =
      CMSampleBufferGetSampleAttachmentsArray(buffer, createIfNecessary: false)
      as? [[SCStreamFrameInfo: Any]]
    let shown = (attachments?.first?[.displayTime] as? NSNumber)?.uint64Value ?? ticks()
    let ready = !palette.withLock { $0.active.isEmpty }
    state.withLock { state in
      state.colors = colors
      guard ready, let request = state.request, state.matched == nil, shown >= request.started,
        colors.indices.allSatisfy({ isActive(colors[$0]) == ($0 == request.active) })
      else { return }
      state.matched = shown
    }
  }
}

// MARK: statistics

private struct Series {
  var values: [Double] = []
  var failures = 0

  var summary: [String: Any] {
    let sorted = values.sorted()
    guard !sorted.isEmpty else { return ["samples": 0, "failures": failures] }
    func rank(_ p: Double) -> Double { sorted[max(0, Int(ceil(Double(sorted.count) * p)) - 1)] }
    return [
      "samples": sorted.count, "failures": failures, "median_ms": rank(0.5), "p90_ms": rank(0.9),
      "max_ms": sorted.last!, "values_ms": values,
    ]
  }

  func line(_ name: String) -> String {
    let sorted = values.sorted()
    guard !sorted.isEmpty else {
      return
        "\(name.padding(toLength: 30, withPad: " ", startingAt: 0)) no samples, \(failures) failures"
    }
    func rank(_ p: Double) -> Double { sorted[max(0, Int(ceil(Double(sorted.count) * p)) - 1)] }
    return String(
      format: "%@ n=%3d fail=%2d  median %7.1f  p90 %7.1f  max %7.1f ms",
      name.padding(toLength: 30, withPad: " ", startingAt: 0), sorted.count, failures, rank(0.5),
      rank(0.9),
      sorted.last!)
  }
}

@main
private struct RealWorldBench {
  static func main() async {
    do { try await run() } catch {
      fputs("realworld-perf: \(error)\n", stderr)
      exit(1)
    }
  }

  static func windows(space: Int) throws -> [[String: Any]] {
    json(try y("query", "--windows", "--space", String(space))) as? [[String: Any]] ?? []
  }

  static func treeLeaves(_ node: [String: Any]) -> [UInt32] {
    var leaves: [UInt32] = []
    if let id = node["window"] as? NSNumber { leaves.append(id.uint32Value) }
    for child in node["nodes"] as? [[String: Any]] ?? [] { leaves += treeLeaves(child) }
    return leaves
  }

  // Runs one sample: spawns the command and polls `done` until it holds and the command exited.
  // Returns the command round trip and the time `done` first held, both from the spawn, or nil when the
  // command failed or `done` did not hold in time.
  static func sample(_ args: [String], timeout: Double = 3000, done: () -> Bool) throws -> (
    Double, Double
  )? {
    if done() {
      print("  yabai -m \(args.joined(separator: " ")): result already shown before the command")
      return nil
    }
    let started = ticks()
    let pid = try spawn(args)
    var exited: UInt64?
    var observed: UInt64?
    while exited == nil || observed == nil {
      if exited == nil {
        var status: Int32 = 0
        if waitpid(pid, &status, WNOHANG) == pid {
          exited = ticks()
          if status != 0 {
            let message = (try? String(contentsOfFile: errorLog, encoding: .utf8)) ?? ""
            print(
              "  yabai -m \(args.joined(separator: " ")): \(message.trimmingCharacters(in: .newlines))"
            )
            return nil
          }
        }
      }
      if observed == nil, done() { observed = ticks() }
      if ms(started, ticks()) > timeout {
        print("  yabai -m \(args.joined(separator: " ")): no result after \(Int(timeout)) ms")
        if exited == nil { waitpid(pid, nil, 0) }
        return nil
      }
      usleep(1000)
    }
    return (ms(started, exited!), ms(started, observed!))
  }

  static func run() async throws {
    let args = CommandLine.arguments
    let samples = args.count > 1 ? Int(args[1]) ?? 30 : 30
    let output = args.count > 2 ? args[2] : nil
    guard !isLocked() else { throw BenchError("the desktop is locked") }
    let apps = ["com.apple.TextEdit", "com.apple.ScriptEditor2", "com.apple.calculator"]
    for app in apps
    where !NSRunningApplication.runningApplications(withBundleIdentifier: app).isEmpty {
      throw BenchError("\(app) is running; quit it first")
    }

    // Remember what to restore: the focused window and the visible space of space 4's display.
    let focused =
      (json(try y("query", "--windows", "--window", allowFailure: true)) as? [String: Any])?["id"]
    let spaces = json(try y("query", "--spaces")) as? [[String: Any]] ?? []
    let display = spaces.first { $0["index"] as? Int == 4 }?["display"] as? Int
    let visible = spaces.first {
      $0["display"] as? Int == display && $0["is-visible"] as? Bool == true
    }?["index"]
    defer {
      osa("tell application \"TextEdit\" to quit saving no")
      osa("tell application \"Script Editor\" to quit saving no")
      osa("tell application \"Calculator\" to quit")
      pause(1)
      if let space = visible as? Int {
        _ = try? y("space", "--focus", String(space), allowFailure: true)
      }
      pause(0.5)
      if let id = focused as? NSNumber {
        _ = try? y("window", "--focus", id.stringValue, allowFailure: true)
      }
    }

    // Fixture: TextEdit A and C and Script Editor B tiled on space 4, Calculator D alone on space 5. D is
    // an app of its own: activating an app with a window on the other space makes macOS switch back to it.
    try y("space", "--focus", "5", allowFailure: true)
    pause(0.6)
    _ = try shell("/usr/bin/open", ["-a", "Calculator"])
    pause(1.5)
    guard
      let d = try windows(space: 5).first(where: { $0["app"] as? String == "Calculator" })
        .map({ ($0["id"] as! NSNumber).uint32Value })
    else { throw BenchError("no Calculator window on space 5") }
    try y("space", "--focus", "4", allowFailure: true)
    pause(0.6)
    _ = try shell("/usr/bin/open", ["-a", "TextEdit"])
    pause(1.5)
    osa("tell application \"TextEdit\" to close (every window whose name is not \"Untitled\")")
    for _ in 0..<2 {
      osa("tell application \"TextEdit\" to make new document")
      pause(0.5)
    }
    _ = try shell("/usr/bin/open", ["-a", "Script Editor"])
    pause(1.5)
    osa("tell application \"Script Editor\" to close (every window whose name is not \"Untitled\")")
    osa("tell application \"Script Editor\" to make new document")
    pause(1.5)
    let leaves = Set(
      treeLeaves(json(try y("query", "--tree", "--space", "4")) as? [String: Any] ?? [:]))
    let tiled = try windows(space: 4).filter {
      leaves.contains(($0["id"] as! NSNumber).uint32Value)
    }
    let text = tiled.filter { $0["app"] as? String == "TextEdit" }.map {
      ($0["id"] as! NSNumber).uint32Value
    }
    let script = tiled.filter { $0["app"] as? String == "Script Editor" }.map {
      ($0["id"] as! NSNumber).uint32Value
    }
    guard text.count >= 2, let b = script.first else {
      throw BenchError("fixture incomplete: TextEdit \(text), Script Editor \(script) on space 4")
    }
    let (a, c) = (text[0], text[1])
    try y("window", "--focus", String(a))
    try y("space", "4", "--balance")
    pause(1)
    print(
      "fixture: A=\(a) (TextEdit) B=\(b) (Script Editor) C=\(c) (TextEdit) on space 4, D=\(d) (Calculator) on space 5"
    )

    var results: [String: [String: Any]] = [:]
    func record(_ name: String, _ series: Series) {
      results[name] = series.summary
      print(series.line(name))
    }

    // Border pixels: the middle of the left border edge of A's and B's tiles.
    guard let frameA = bounds(a), let frameB = bounds(b), frameA != frameB else {
      throw BenchError("A and B have no distinct window server frames")
    }
    let borderWidth = Double(try y("config", "window_border_width")) ?? 3
    let borderOn = try y("config", "window_border") == "on"
    let points = [frameA, frameB].map { CGPoint(x: $0.minX - borderWidth / 2, y: $0.midY) }
    var monitor: PixelMonitor?
    var stream: SCStream?
    if borderOn && CGPreflightScreenCaptureAccess() {
      let content = try await SCShareableContent.excludingDesktopWindows(
        false, onScreenWindowsOnly: true)
      if let display = content.displays.first(where: {
        CGDisplayBounds($0.displayID).contains(points[0])
      }) {
        let rect = CGDisplayBounds(display.displayID)
        let configuration = SCStreamConfiguration()
        configuration.width = Int(rect.width)
        configuration.height = Int(rect.height)
        configuration.pixelFormat = kCVPixelFormatType_32BGRA
        configuration.minimumFrameInterval = CMTime(value: 1, timescale: 120)
        configuration.queueDepth = 3
        configuration.showsCursor = false
        let pixels = PixelMonitor(points: points, display: rect)
        let capture = SCStream(
          filter: SCContentFilter(display: display, excludingWindows: []),
          configuration: configuration,
          delegate: nil)
        try capture.addStreamOutput(
          pixels, type: .screen, sampleHandlerQueue: DispatchQueue(label: "capture"))
        try await capture.startCapture()
        try await Task.sleep(for: .milliseconds(500))
        // A is focused: its edge shows the active color, B's the normal one.
        let colors = pixels.state.withLock { $0.colors }
        if colors.count == 2 && colors[0] != colors[1] {
          pixels.palette.withLock { $0 = (colors[0], colors[1]) }
          monitor = pixels
          stream = capture
          print("border colors: active \(colors[0]) normal \(colors[1])")
        }
      }
    } else {
      print(
        "border metrics skipped: window_border \(borderOn ? "on" : "off"), screen recording "
          + "\(CGPreflightScreenCaptureAccess() ? "granted" : "denied")")
    }

    func requestBorder(active: Int) {
      monitor?.state.withLock {
        $0.request = (ticks(), active)
        $0.matched = nil
      }
    }
    func borderLatency() -> Double? {
      guard let monitor else { return nil }
      return monitor.state.withLock { state in
        guard let request = state.request, let shown = state.matched else { return nil }
        return ms(request.started, shown)
      }
    }
    func waitBorder() -> Double? {
      guard monitor != nil else { return nil }
      let deadline = ticks()
      while ms(deadline, ticks()) < 2000 {
        if let value = borderLatency() { return value }
        usleep(1000)
      }
      return nil
    }

    // 1. Focus: A and B (different apps) in turn. Done when the target is the front window of the fixture.
    var focusCommand = Series()
    var focusFront = Series()
    var focusBorder = Series()
    let fixture: Set<UInt32> = [a, b, c]
    for index in 0..<(samples + 3) {
      guard !isLocked() else { throw BenchError("the desktop locked during the run") }
      let target = index % 2 == 0 ? b : a
      requestBorder(active: target == a ? 0 : 1)
      let result = try sample(["window", "--focus", String(target)]) {
        onScreenOrder(fixture).first == target
      }
      let border = waitBorder()
      guard index >= 3 else { continue }
      if let (command, front) = result {
        focusCommand.values.append(command)
        focusFront.values.append(front)
      } else {
        focusFront.failures += 1
      }
      if monitor != nil {
        if let border { focusBorder.values.append(border) } else { focusBorder.failures += 1 }
      }
      pause(0.15)
    }
    record("focus: command round trip", focusCommand)
    record("focus: window in front", focusFront)
    if monitor != nil { record("focus: border on screen", focusBorder) }

    // 2. Move: swap A (focused) and B. Done when each has the other's window server origin (an app's
    // minimum size can make a window larger than its tile, so the sizes need not swap).
    try y("window", "--focus", String(a))
    pause(0.5)
    var moveCommand = Series()
    var moveFrames = Series()
    var moveBorder = Series()
    for index in 0..<(samples + 3) {
      guard !isLocked() else { throw BenchError("the desktop locked during the run") }
      let (toA, toB) = index % 2 == 0 ? (frameB, frameA) : (frameA, frameB)
      requestBorder(active: index % 2 == 0 ? 1 : 0)
      let result = try sample(["window", String(a), "--swap", String(b)]) {
        bounds(a)?.origin == toA.origin && bounds(b)?.origin == toB.origin
      }
      let border = waitBorder()
      guard index >= 3 else { continue }
      if let (command, frames) = result {
        moveCommand.values.append(command)
        moveFrames.values.append(frames)
      } else {
        moveFrames.failures += 1
        print(
          "  swap \(index): A \(bounds(a).map { "\($0)" } ?? "?") want \(toA), B \(bounds(b).map { "\($0)" } ?? "?") want \(toB)"
        )
      }
      if monitor != nil {
        if let border { moveBorder.values.append(border) } else { moveBorder.failures += 1 }
      }
      pause(0.25)
    }
    record("swap: command round trip", moveCommand)
    record("swap: frames applied", moveFrames)
    if monitor != nil { record("swap: border on screen", moveBorder) }
    if bounds(a) != frameA { try y("window", String(a), "--swap", String(b)) }

    // 3. Space: 4 and 5 in turn. Done when the target space's window is on screen and the other is not.
    var spaceCommand = Series()
    var spaceShown = Series()
    for index in 0..<(samples + 3) {
      guard !isLocked() else { throw BenchError("the desktop locked during the run") }
      let (space, shown, hidden) = index % 2 == 0 ? (5, d, a) : (4, a, d)
      let result = try sample(["space", "--focus", String(space)]) {
        let order = onScreenOrder([shown, hidden])
        return order == [shown]
      }
      guard index >= 3 else { continue }
      if let (command, shownAt) = result {
        spaceCommand.values.append(command)
        spaceShown.values.append(shownAt)
      } else {
        spaceShown.failures += 1
      }
      pause(0.3)
    }
    record("space: command round trip", spaceCommand)
    record("space: windows on screen", spaceShown)

    try? await stream?.stopCapture()
    if let output {
      let data = try JSONSerialization.data(
        withJSONObject: [
          "version": (try? shell(yabai, ["--version"])) ?? "", "samples": samples,
          "border_width": borderWidth, "windows": ["A": a, "B": b, "C": c, "D": d],
          "results": results,
        ], options: [.prettyPrinted, .sortedKeys])
      try data.write(to: URL(fileURLWithPath: output))
      print("wrote \(output)")
    }
  }
}
