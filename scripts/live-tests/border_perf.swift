import AppKit
import CoreMedia
import CoreVideo
import ScreenCaptureKit
import Synchronization

// Command-to-visible-border latency, sampled by a persistent display stream.
// Compile: swiftc -O -swift-version 6 -parse-as-library border_perf.swift -o /tmp/yabai-border-perf
// Run after live.py setup: /tmp/yabai-border-perf LABEL OUTPUT.json [SAMPLES] [focus|move]
// Only TextEdit/Script Editor windows on space 4 are focused. Config is restored.

private func ticks() -> UInt64 { mach_absolute_time() }
private let millisecondsPerTick: Double = {
    var info = mach_timebase_info_data_t()
    mach_timebase_info(&info)
    return Double(info.numer) / Double(info.denom) / 1_000_000
}()

private struct Request
{
    let token: Int
    let started: UInt64
    let red: Int
    let blue: Int
    let sourceMustBeBlue: Bool
}

private struct Observation
{
    let token: Int
    let callback: UInt64
    let displayed: UInt64?
}

private struct CaptureState
{
    var colors: [[UInt8]] = []
    var request: Request?
    var observation: Observation?
    var frames = 0
}

// NOTE: Stream callbacks run on the capture queue; all mutable state is protected
// by the mutex. The immutable points and display bounds are shared values.
private final class PixelMonitor: NSObject, SCStreamOutput, @unchecked Sendable
{
    let points: [CGPoint]
    let bounds: CGRect
    let state = Mutex(CaptureState())

    init(points: [CGPoint], bounds: CGRect)
    {
        self.points = points
        self.bounds = bounds
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer buffer: CMSampleBuffer, of type: SCStreamOutputType)
    {
        guard type == .screen, let pixels = CMSampleBufferGetImageBuffer(buffer) else { return }
        CVPixelBufferLockBaseAddress(pixels, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pixels, .readOnly) }
        guard let address = CVPixelBufferGetBaseAddress(pixels) else { return }
        let width = CVPixelBufferGetWidth(pixels)
        let height = CVPixelBufferGetHeight(pixels)
        let stride = CVPixelBufferGetBytesPerRow(pixels)
        let bytes = address.assumingMemoryBound(to: UInt8.self)
        var colors: [[UInt8]] = []
        for point in points {
            let x = min(width - 1, max(0, Int((point.x - bounds.minX) * Double(width) / bounds.width)))
            let y = min(height - 1, max(0, Int((point.y - bounds.minY) * Double(height) / bounds.height)))
            let offset = y * stride + x * 4
            colors.append([bytes[offset + 2], bytes[offset + 1], bytes[offset]])
        }
        let callback = ticks()
        let attachments = CMSampleBufferGetSampleAttachmentsArray(buffer, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]]
        let displayed = (attachments?.first?[.displayTime] as? NSNumber)?.uint64Value
        state.withLock { state in
            state.frames += 1
            state.colors = colors
            guard let request = state.request, state.observation == nil,
                  displayed == nil || displayed! >= request.started,
                  Self.isRed(colors[request.red]),
                  request.sourceMustBeBlue ? Self.isBlue(colors[request.blue]) : !Self.isRed(colors[request.blue]) else { return }
            state.observation = Observation(token: request.token, callback: callback, displayed: displayed)
        }
    }

    static func isRed(_ color: [UInt8]) -> Bool { color.count == 3 && color[0] > 180 && color[1] < 90 && color[2] < 90 }
    static func isBlue(_ color: [UInt8]) -> Bool { color.count == 3 && color[2] > 180 && color[0] < 90 && color[1] < 90 }
}

private struct BenchError: Error, CustomStringConvertible
{
    let description: String
    init(_ description: String) { self.description = description }
}

@main
private struct BorderBench
{
    static let executable = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".local/bin/yabai").path

    @discardableResult
    static func command(_ args: [String], allowFailure: Bool = false) throws -> String
    {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = ["-m"] + args
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

    static func waitFor(_ operation: () -> Bool) async throws
    {
        let start = ticks()
        while !operation() {
            if Double(ticks() - start) * millisecondsPerTick > 3000 { throw BenchError("pixel observation timed out") }
            try await Task.sleep(for: .milliseconds(2))
        }
    }

    static func stats(_ values: [Double]) -> [String: Any]
    {
        let sorted = values.sorted()
        guard !sorted.isEmpty else { return ["samples": 0] }
        func p(_ fraction: Double) -> Double { sorted[max(0, Int(ceil(Double(sorted.count) * fraction)) - 1)] }
        let middle = sorted.count / 2
        let median = sorted.count % 2 == 0 ? (sorted[middle - 1] + sorted[middle]) / 2 : sorted[middle]
        return ["samples": values.count, "median_ms": median, "p90_ms": p(0.90), "p95_ms": p(0.95),
                "max_ms": sorted.last!, "values_ms": values]
    }

    static func main() async
    {
        do { try await run() }
        catch { fputs("border benchmark: \(error)\n", stderr); exit(1) }
    }

    static func ensureUnlocked() throws
    {
        guard let session = CGSessionCopyCurrentDictionary() as? [String: Any] else {
            throw BenchError("cannot determine desktop lock state; no live measurement allowed")
        }
        if session["CGSSessionScreenIsLocked"] as? Bool == true {
            throw BenchError("desktop is locked; no live measurement allowed")
        }
    }

    static func run() async throws
    {
        let args = CommandLine.arguments
        guard args.count >= 3 else { throw BenchError("usage: border-perf LABEL OUTPUT.json [SAMPLES]") }
        let samples = args.count > 3 ? Int(args[3]) ?? 40 : 40
        let moving = args.count > 4 && args[4] == "move"
        guard samples >= 3 else { throw BenchError("at least 3 samples required") }
        try ensureUnlocked()
        guard CGPreflightScreenCaptureAccess() else { throw BenchError("Screen Recording access unavailable") }
        let json = try command(["query", "--windows", "--space", "4"])
        let windows = try JSONSerialization.jsonObject(with: Data(json.utf8)) as! [[String: Any]]
        let text = windows.filter { $0["app"] as? String == "TextEdit" && $0["is-floating"] as? Bool == false }
        let script = windows.filter { $0["app"] as? String == "Script Editor" && $0["is-floating"] as? Bool == false }
        guard text.count >= 2, !script.isEmpty else { throw BenchError("need 2 tiled TextEdit and 1 tiled Script Editor windows on space 4") }
        let ids = [text[0], text[1], script[0]].map { ($0["id"] as! NSNumber).uint32Value }
        let names = ["window_border", "window_border_width", "window_border_hide_single", "active_window_border_color",
                     "normal_window_border_color", "focus_follows_mouse", "mouse_follows_focus", "window_animation_duration"]
        var saved: [String: String] = [:]
        var floated = false
        var floatingOrigin = CGPoint.zero
        for name in names { saved[name] = try command(["config", name]) }
        if saved["focus_follows_mouse"] == "disabled" { saved["focus_follows_mouse"] = "off" }
        defer {
            if floated {
                _ = try? command(["window", String(ids[0]), "--move", "abs:\(floatingOrigin.x):\(floatingOrigin.y)"])
                _ = try? command(["window", String(ids[0]), "--toggle", "float"])
            }
            for name in names {
                if let value = saved[name] { _ = try? command(["config", name, value]) }
            }
        }
        try command(["space", "--focus", "4"], allowFailure: true)
        try command(["window", "--focus", String(ids[0])])
        try command(["window", String(ids[0]), "--layout", "splith"])
        try command(["config", "window_animation_duration", "0", "focus_follows_mouse", "off", "mouse_follows_focus", "off",
                     "window_border_width", "6", "window_border_hide_single", "off", "active_window_border_color", "0xffff0000",
                     "normal_window_border_color", "0xff0000ff", "window_border", "on"])
        try await Task.sleep(for: .seconds(1))
        if moving {
            try command(["window", String(ids[0]), "--toggle", "float"])
            floated = true
            try await Task.sleep(for: .milliseconds(400))
        }
        var points: [CGPoint] = []
        for id in moving ? [ids[0]] : ids {
            let value = try command(["query", "--windows", "--window", String(id)])
            let window = try JSONSerialization.jsonObject(with: Data(value.utf8)) as! [String: Any]
            let frame = window["frame"] as! [String: NSNumber]
            points.append(CGPoint(x: frame["x"]!.doubleValue - 3, y: frame["y"]!.doubleValue + frame["h"]!.doubleValue / 2))
            if moving {
                floatingOrigin = CGPoint(x: frame["x"]!.doubleValue, y: frame["y"]!.doubleValue)
                points.append(CGPoint(x: points[0].x + 40, y: points[0].y))
            }
        }
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        guard let display = content.displays.first(where: { CGDisplayBounds($0.displayID).contains(points[0]) }) else {
            throw BenchError("cannot locate test display")
        }
        let bounds = CGDisplayBounds(display.displayID)
        guard points.allSatisfy({ bounds.contains($0) }) else { throw BenchError("test windows must be on one display") }
        let filter = SCContentFilter(display: display, excludingWindows: [])
        let configuration = SCStreamConfiguration()
        configuration.width = Int(bounds.width)
        configuration.height = Int(bounds.height)
        configuration.pixelFormat = kCVPixelFormatType_32BGRA
        configuration.minimumFrameInterval = CMTime(value: 1, timescale: 120)
        configuration.queueDepth = 3
        configuration.showsCursor = false
        configuration.capturesAudio = false
        let monitor = PixelMonitor(points: points, bounds: bounds)
        let stream = SCStream(filter: filter, configuration: configuration, delegate: nil)
        try stream.addStreamOutput(monitor, type: .screen, sampleHandlerQueue: DispatchQueue(label: "yabai.border-perf.capture"))
        try await stream.startCapture()
        var records: [String: Any] = [:]
        var token = 0
        do {
            let groups = moving ? [("floating-move-visible-border", (0, 1))] : [("same-app-visible-border", (0, 1)), ("cross-app-visible-border", (0, 2))]
            for (name, pair) in groups {
                var displayed: [Double] = []
                var delivered: [Double] = []
                var commands: [Double] = []
                var failures: [String] = []
                for index in 0..<(samples + 5) {
                    try ensureUnlocked()
                    let source = index % 2 == 0 ? pair.0 : pair.1
                    let target = index % 2 == 0 ? pair.1 : pair.0
                    let prepare = moving ? ["window", String(ids[0]), "--move", "abs:\(floatingOrigin.x + Double(source) * 40):\(floatingOrigin.y)"] : ["window", "--focus", String(ids[source])]
                    try command(prepare)
                    do {
                        try await waitFor {
                            monitor.state.withLock {
                                $0.colors.count == points.count && PixelMonitor.isRed($0.colors[source]) &&
                                    (moving ? !PixelMonitor.isRed($0.colors[target]) : PixelMonitor.isBlue($0.colors[target]))
                            }
                        }
                    } catch {
                        let diagnostic = monitor.state.withLock { "frames=\($0.frames), colors=\($0.colors), points=\(points)" }
                        throw BenchError("source border did not become observable: \(diagnostic)")
                    }
                    token += 1
                    let started = ticks()
                    monitor.state.withLock {
                        $0.observation = nil
                        $0.request = Request(token: token, started: started, red: target, blue: source, sourceMustBeBlue: !moving)
                    }
                    let action = moving ? ["window", String(ids[0]), "--move", "abs:\(floatingOrigin.x + Double(target) * 40):\(floatingOrigin.y)"] : ["window", "--focus", String(ids[target])]
                    try command(action)
                    let returned = ticks()
                    do {
                        try await waitFor { monitor.state.withLock { $0.observation?.token == token } }
                        let observed = monitor.state.withLock { $0.observation! }
                        if index >= 5 {
                            commands.append(Double(returned - started) * millisecondsPerTick)
                            delivered.append(Double(observed.callback - started) * millisecondsPerTick)
                            if let frame = observed.displayed { displayed.append(Double(frame - started) * millisecondsPerTick) }
                        }
                    } catch {
                        failures.append("sample \(index): \(error)")
                    }
                    monitor.state.withLock { $0.request = nil }
                    try await Task.sleep(for: .milliseconds(100))
                }
                records[name] = ["displayed": stats(displayed), "capture_callback": stats(delivered), "command_roundtrip": stats(commands), "failures": failures]
                print("\(name): \(stats(displayed)) failures=\(failures)")
            }
        } catch {
            try? await stream.stopCapture()
            throw error
        }
        try await stream.stopCapture()
        try ensureUnlocked()
        let result: [String: Any] = ["label": args[1], "mode": moving ? "move" : "focus", "border_width": 6, "samples_requested": samples, "points": points.map { ["x": $0.x, "y": $0.y] },
                                   "window_ids": ids, "display_bounds": ["x": bounds.minX, "y": bounds.minY, "w": bounds.width, "h": bounds.height],
                                   "capture_requested_hz": 120, "frames_received": monitor.state.withLock { $0.frames }, "measurements": records,
                                   "method": "Start immediately before spawning yabai -m window --focus (focus mode) or --move abs (move mode). First ScreenCaptureKit frame showing target edge red and source edge blue (focus) or no longer red (move); displayTime is window-server display time, callback also recorded. Pixel classification is at each left edge midpoint. Includes CLI startup and screen presentation quantization; not an internal drawing benchmark."]
        let data = try JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: URL(fileURLWithPath: args[2]))
    }
}
