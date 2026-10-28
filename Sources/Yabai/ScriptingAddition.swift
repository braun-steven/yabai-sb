import Algorithms
import AppKit
import CPrivate
import Darwin
import OSAX
import Subprocess
import System
import YabaiCore

private let saVersion = String(cString: sa_payload_version())

// Request fields retain their native integer/float layout. Replies accept
// an optional status byte, and legacy payload EOF remains an explicitly unconfirmed success.

/// A window ordered relative to another one; the payload gets the fields one by one.
struct WindowOrder: Equatable {
  var window: WindowID
  var order: Int32
  var relativeTo: WindowID?
}

private enum SAPath {
  static let base = "/Library/ScriptingAdditions/yabai.osax"
  static let contents = base + "/Contents"
  static let macOS = contents + "/MacOS"
  static let resources = contents + "/Resources"
  static let info = contents + "/Info.plist"
  static let payload = resources + "/payload.bundle"
  static let payloadContents = payload + "/Contents"
  static let payloadMacOS = payloadContents + "/MacOS"
  static let payloadInfo = payloadContents + "/Info.plist"
  static let payloadBinary = payloadMacOS + "/payload"
  static let loaderBinary = macOS + "/loader"
}

private let saPlist = """
  <?xml version="1.0" encoding="UTF-8"?>
  <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
  <plist version="1.0">
  <dict>
  <key>CFBundleDevelopmentRegion</key>
  <string>en</string>
  <key>CFBundleExecutable</key>
  <string>loader</string>
  <key>CFBundleIdentifier</key>
  <string>com.asmvik.yabai-osax</string>
  <key>CFBundleInfoDictionaryVersion</key>
  <string>6.0</string>
  <key>CFBundleName</key>
  <string>yabai</string>
  <key>CFBundlePackageType</key>
  <string>osax</string>
  <key>CFBundleShortVersionString</key>
  <string>\(saVersion)</string>
  <key>CFBundleVersion</key>
  <string>\(saVersion)</string>
  <key>NSHumanReadableCopyright</key>
  <string>Copyright © 2019 Åsmund Vikane. Fork modifications © 2026 Steven Braun. All rights reserved.</string>
  <key>OSAXHandlers</key>
  <dict>
  </dict>
  </dict>
  </plist>
  """

private let saBundlePlist = """
  <?xml version="1.0" encoding="UTF-8"?>
  <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
  <plist version="1.0">
  <dict>
  <key>CFBundleDevelopmentRegion</key>
  <string>en</string>
  <key>CFBundleExecutable</key>
  <string>payload</string>
  <key>CFBundleIdentifier</key>
  <string>com.asmvik.yabai-sa</string>
  <key>CFBundleInfoDictionaryVersion</key>
  <string>6.0</string>
  <key>CFBundleName</key>
  <string>payload</string>
  <key>CFBundlePackageType</key>
  <string>BNDL</string>
  <key>CFBundleShortVersionString</key>
  <string>\(saVersion)</string>
  <key>CFBundleVersion</key>
  <string>\(saVersion)</string>
  <key>NSHumanReadableCopyright</key>
  <string>Copyright © 2019 Åsmund Vikane. Fork modifications © 2026 Steven Braun. All rights reserved.</string>
  <key>NSPrincipalClass</key>
  <string></string>
  </dict>
  </plist>
  """

final class ScriptingAddition: Sendable {
  // NOTE: The single scripting addition, used by the event loop and the IPC handlers it runs.
  static let shared = ScriptingAddition()

  // NOTE: The sockets of the payload, resolved once in init and immutable afterwards, so any thread may read them:
  // socketPath (for the user in $USER) is used by the daemon's event loop (send, payloadIsCurrent), sudoSocketPath
  // (for the user of SUDO_UID, only when running as root) by --load-sa.
  let socketPath: String?
  private let sudoSocketPath: String?

  //
  // NOTE: A daemon can talk to the payload of an older yabai until Dock is restarted, and an older
  // payload ignores opcodes it does not know. Whether the payload is current is asked once with a
  // handshake and remembered until Dock restarts. An outdated payload gets one message per window.
  // The cache is @WM: only the event loop reads it and payloadChanged resets it.
  //

  @WM private var payloadIsCurrentCache: Bool?

  private init() {
    socketPath = ProcessEnvironment.currentUser().map { "/tmp/yabai-sa_\($0).socket" }
    sudoSocketPath = Self.resolveSudoSocketPath()
  }

  private static func resolveSudoSocketPath() -> String? {
    guard getuid() == 0, let uid = SAConnection.sudoUID(), let pw = getpwuid(uid),
      let name = pw.pointee.pw_name
    else { return nil }
    return "/tmp/yabai-sa_\(String(cString: name)).socket"
  }

  private func createDirectory() -> Bool {
    for path in [
      SAPath.base, SAPath.contents, SAPath.macOS, SAPath.resources, SAPath.payload,
      SAPath.payloadContents, SAPath.payloadMacOS,
    ] {
      if mkdir(path, 0o755) != 0 { return false }
    }
    return true
  }

  private func writeFile(_ bytes: UnsafeRawPointer?, _ size: Int, _ path: String, _ mode: String)
    -> Bool
  {
    guard let handle = fopen(path, mode) else { return false }
    let result = fwrite(bytes, size, 1, handle) == 1
    return fclose(handle) == 0 && result
  }

  private func writeFile(_ text: String, _ path: String) -> Bool {
    text.withCString { writeFile($0, text.utf8.count, path, "w") }
  }

  private func prepareBinaries() async -> Bool {
    for path in [SAPath.loaderBinary, SAPath.payloadBinary] {
      guard chmod(path, 0o755) == 0 else { return false }
      let status = try? await run(
        .path("/usr/bin/codesign"), arguments: ["-f", "-s", "-", path],
        output: .currentStandardOutput, error: .currentStandardError
      ).terminationStatus
      guard status?.isSuccess == true else { return false }
    }
    return true
  }

  private func report(_ text: String) {
    notify("scripting-addition", text)
  }

  private func restartDock() {
    autoreleasepool {
      for dock in NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.dock") {
        dock.terminate()
      }
    }
  }

  private var isInstalled: Bool {
    guard let dir = opendir(SAPath.base) else { return false }
    closedir(dir)
    return true
  }

  private func check() -> Int32 {
    autoreleasepool {
      guard isInstalled, let bundle = Bundle(path: SAPath.payload),
        let version = bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String
      else { return 1 }
      return version.utf8.elementsEqual(saVersion.utf8) ? 0 : 1
    }
  }

  @discardableResult private func remove() -> Bool {
    (try? FileManager.default.removeItem(atPath: SAPath.base)) != nil
  }

  private func install() async -> Int32 {
    let previousMask = umask(mode_t(S_IWGRP | S_IWOTH))
    defer { umask(previousMask) }
    if isInstalled && !remove() { return 1 }
    guard createDirectory(),
      writeFile(saPlist, SAPath.info),
      writeFile(saBundlePlist, SAPath.payloadInfo),
      writeFile(sa_loader_bytes(), Int(sa_loader_size()), SAPath.loaderBinary, "wb"),
      writeFile(sa_payload_bytes(), Int(sa_payload_size()), SAPath.payloadBinary, "wb"),
      await prepareBinaries()
    else {
      remove()
      return 2
    }
    restartDock()
    return 0
  }

  private func requestHandshake(socketPath: String) -> (version: [UInt8], attributes: UInt32)? {
    var sockfd: Int32 = 0
    guard UnixSocket.open(&sockfd) else { return nil }
    defer { UnixSocket.close(sockfd) }
    guard let connection = SAConnection(fd: sockfd), connection.connect(socketPath) else {
      return nil
    }
    return connection.handshake()
  }

  /// Whether the payload that answers at `socketPath` is the one this build embeds. It waits on the socket, so it runs
  /// off the event loop (ScriptingAdditionLoader).
  func payloadMatches(socketPath: String) -> Bool {
    guard let handshake = requestHandshake(socketPath: socketPath) else { return false }
    return handshake.version.elementsEqual(saVersion.utf8)
  }

  enum AttributeVerdict: Equatable {
    case supported
    case missingAnimation
    case unsupported
  }

  // NOTE: OSAX_ATTRIB_ALL (the macro combines macros and does not import). Every bit but OSAX_ATTRIB_ANIM_TIME is
  // required; a missing animation bit only costs the space animation patch.
  static func attributeVerdict(_ attributes: UInt32) -> AttributeVerdict {
    let required = UInt32(
      OSAX_ATTRIB_DOCK_SPACES | OSAX_ATTRIB_DPPM | OSAX_ATTRIB_ADD_SPACE | OSAX_ATTRIB_REM_SPACE
        | OSAX_ATTRIB_MOV_SPACE)
    if attributes & required != required { return .unsupported }
    return attributes & UInt32(OSAX_ATTRIB_ANIM_TIME) != 0 ? .supported : .missingAnimation
  }

  private func performValidation(socketPath: String) async -> Int32 {
    let isLatestInstalled = check() == 0
    guard let handshake = requestHandshake(socketPath: socketPath) else {
      report("connection failed!")
      return 1
    }
    if handshake.version.elementsEqual(saVersion.utf8) {
      let version = String(decoding: handshake.version, as: UTF8.self)
      switch Self.attributeVerdict(handshake.attributes) {
      case .supported:
        report("payload v\(version)")
        return 0
      case .missingAnimation:
        // NOTE: Only the animation bit is optional: its patch is skipped for Dock builds that are not validated.
        report("payload v\(version): space animation patch unavailable for this Dock build")
        return 0
      case .unsupported:
        report(
          "payload (0x\(String(handshake.attributes, radix: 16, uppercase: true))) doesn't support this macOS version!"
        )
        return 1
      }
    }
    if !isLatestInstalled {
      report("payload is outdated, updating..")
      return await install()
    }
    report("payload is outdated, restarting Dock.app..")
    restartDock()
    return 0
  }

  var isSIPFriendly: Bool {
    var config: UInt32 = 0
    csr_get_active_config(&config)
    // CSR_ALLOW_UNRESTRICTED_FS, CSR_ALLOW_TASK_FOR_PID
    return config & 0x02 != 0 && config & 0x04 != 0
  }

  private var isArm64eEnabled: Bool {
    var args = [CChar](repeating: 0, count: 2048)
    var length = args.count - 1
    return sysctlbyname("kern.bootargs", &args, &length, nil, 0) == 0
      && strnstr(args, "-arm64e_preview_abi", length) != nil
  }

  private func injectPayload() async -> Bool {
    let status = try? await run(
      .path(FilePath(SAPath.loaderBinary)), output: .discarded, error: .currentStandardError
    ).terminationStatus
    return status?.isSuccess == true
  }

  func uninstall() -> Int32 {
    if !isSIPFriendly {
      Client.writeAll(
        STDERR_FILENO,
        "yabai: System Integrity Protection: Filesystem Protections and Debugging Restrictions must be disabled!\n"
          .utf8)
      report(
        "System Integrity Protection: Filesystem Protections and Debugging Restrictions must be disabled!"
      )
      return 1
    }
    if !Daemon.isRoot {
      Client.writeAll(
        STDERR_FILENO, "yabai: scripting-addition must be uninstalled as root!\n".utf8)
      report("must be uninstalled as root!")
      return 1
    }
    if !isInstalled { return 0 }
    return remove() ? 0 : -1
  }

  func load() async -> Int32 {
    if !Daemon.isRoot {
      Client.writeAll(STDERR_FILENO, "yabai: scripting-addition must be loaded as root!\n".utf8)
      report("must be loaded as root!")
      return 1
    }
    if !isSIPFriendly {
      Client.writeAll(
        STDERR_FILENO,
        "yabai: System Integrity Protection: Filesystem Protections and Debugging Restrictions must be disabled!\n"
          .utf8)
      report(
        "System Integrity Protection: Filesystem Protections and Debugging Restrictions must be disabled!"
      )
      return 1
    }
    if check() != 0 { return await install() }
    if !isArm64eEnabled {
      Client.writeAll(
        STDERR_FILENO, "yabai: missing required nvram boot-arg '-arm64e_preview_abi'!\n".utf8)
      report("missing required nvram boot-arg '-arm64e_preview_abi'!")
      return 1
    }
    guard let sudoSocketPath else {
      Client.writeAll(
        STDERR_FILENO, "yabai: cannot determine the scripting-addition user from SUDO_UID!\n".utf8)
      return 1
    }
    if !(await injectPayload()) {
      Client.writeAll(
        STDERR_FILENO, "yabai: scripting-addition failed to inject payload into Dock.app!\n".utf8)
      report("failed to inject payload into Dock.app!")
      return 1
    }
    return await performValidation(socketPath: sudoSocketPath)
  }

  func send(_ bytes: [UInt8]) -> Bool {
    if Headless.isEnabled {
      Headless.record(message: bytes)
      return true
    }
    var sockfd: Int32 = 0
    guard UnixSocket.open(&sockfd) else { return false }
    defer { UnixSocket.close(sockfd) }
    guard let socketPath,
      let connection = SAConnection(fd: sockfd), connection.connect(socketPath)
    else { return false }
    return connection.command(bytes).isSuccess
  }

  @discardableResult func focusSpace(_ sid: SpaceID) -> Bool {
    var payload = SAPayload()
    payload.pack(sid)
    return payload.send(SA_OPCODE_SPACE_FOCUS)
  }

  @discardableResult func createSpace(_ sid: SpaceID) -> Bool {
    var payload = SAPayload()
    payload.pack(sid)
    return payload.send(SA_OPCODE_SPACE_CREATE)
  }

  @discardableResult func destroySpace(_ sid: SpaceID) -> Bool {
    var payload = SAPayload()
    payload.pack(sid)
    return payload.send(SA_OPCODE_SPACE_DESTROY)
  }

  @discardableResult func moveSpace(
    _ src: SpaceID, toDisplayOf dst: SpaceID, previous: SpaceID?, focus: Bool
  ) -> Bool {
    var payload = SAPayload()
    payload.pack(src)
    payload.pack(dst)
    payload.pack(previous?.rawValue ?? 0)
    payload.pack(focus)
    return payload.send(SA_OPCODE_SPACE_MOVE)
  }

  @discardableResult func moveSpace(_ src: SpaceID, after dst: SpaceID, focus: Bool) -> Bool {
    moveSpace(src, toDisplayOf: dst, previous: nil, focus: focus)
  }

  @discardableResult func moveWindow(_ wid: WindowID, x: Int32, y: Int32) -> Bool {
    var payload = SAPayload()
    payload.pack(wid)
    payload.pack(x)
    payload.pack(y)
    return payload.send(SA_OPCODE_WINDOW_MOVE)
  }

  @discardableResult func setLayer(_ layer: Int32, of wid: WindowID) -> Bool {
    var payload = SAPayload()
    payload.pack(wid)
    payload.pack(layer)
    return payload.send(SA_OPCODE_WINDOW_LAYER)
  }

  @discardableResult func setSticky(_ sticky: Bool, of wid: WindowID) -> Bool {
    var payload = SAPayload()
    payload.pack(wid)
    payload.pack(sticky)
    return payload.send(SA_OPCODE_WINDOW_STICKY)
  }

  @discardableResult func setShadow(_ shadow: Bool, of wid: WindowID) -> Bool {
    var payload = SAPayload()
    payload.pack(wid)
    payload.pack(shadow)
    return payload.send(SA_OPCODE_WINDOW_SHADOW)
  }

  @discardableResult func scaleWindow(
    _ wid: WindowID, x: Float, y: Float, width: Float, height: Float
  ) -> Bool {
    var payload = SAPayload()
    payload.pack(wid)
    payload.pack(x)
    payload.pack(y)
    payload.pack(width)
    payload.pack(height)
    return payload.send(SA_OPCODE_WINDOW_SCALE)
  }

  @discardableResult func orderWindow(_ wid: WindowID, _ order: Int32, relativeTo other: WindowID?)
    -> Bool
  {
    var payload = SAPayload()
    payload.pack(wid)
    payload.pack(order)
    payload.pack(other?.rawValue ?? 0)
    return payload.send(SA_OPCODE_WINDOW_ORDER)
  }

  @WM private func payloadIsCurrent() -> Bool {
    if Headless.isEnabled { return true }
    if payloadIsCurrentCache == nil,
      let socketPath,
      let handshake = requestHandshake(socketPath: socketPath)
    {
      payloadIsCurrentCache = handshake.version.elementsEqual(saVersion.utf8)
    }
    return payloadIsCurrentCache == true
  }

  @WM func payloadChanged() {
    payloadIsCurrentCache = nil
  }

  @WM @discardableResult func orderWindows(_ list: [WindowOrder]) -> Bool {
    if list.isEmpty { return true }
    if !payloadIsCurrent() {
      var result = true
      for entry in list {
        result = orderWindow(entry.window, entry.order, relativeTo: entry.relativeTo) && result
      }
      return result
    }
    var result = true
    for chunk in list.chunks(ofCount: 256) {  // SA_WINDOW_ORDER_CHUNK
      var payload = SAPayload()
      payload.pack(Int32(chunk.count))
      for entry in chunk {
        payload.pack(entry.window)
        payload.pack(entry.order)
        payload.pack(entry.relativeTo?.rawValue ?? 0)
      }
      result = payload.send(SA_OPCODE_WINDOW_ORDER_LIST) && result
    }
    return result
  }

  @discardableResult func orderIn(_ windows: [WindowID]) -> Bool {
    var payload = SAPayload()
    payload.pack(Int32(windows.count))
    for wid in windows {
      payload.pack(SLS.windowIsOrderedIn(SLS.connection, wid) ? 0 : wid.rawValue)
    }
    return payload.send(SA_OPCODE_WINDOW_ORDER_IN)
  }

  @discardableResult func moveWindows(_ windows: [WindowID], to sid: SpaceID) -> Bool {
    var payload = SAPayload()
    payload.pack(sid)
    payload.pack(Int32(windows.count))
    for wid in windows { payload.pack(wid) }
    return payload.send(SA_OPCODE_WINDOW_LIST_TO_SPACE)
  }

  @discardableResult func moveWindow(_ wid: WindowID, to sid: SpaceID) -> Bool {
    var payload = SAPayload()
    payload.pack(sid)
    payload.pack(wid)
    return payload.send(SA_OPCODE_WINDOW_TO_SPACE)
  }
}

//
// NOTE: A payload that does not fit the buffer (e.g. a very long window list) is not sent, and the
// operation reports failure so that the caller can fall back, instead of overflowing the stack buffer.
//

struct SAPayload {
  private(set) var bytes: [UInt8] = [0, 0, 0]
  private(set) var overflow = false

  mutating func pack<T>(_ value: T) {
    if bytes.count + MemoryLayout<T>.size > Int(SA_SOCKET_BUFF_LEN) {
      overflow = true
      return
    }
    withUnsafeBytes(of: value) { bytes.append(contentsOf: $0) }
  }

  /// The payload carries ids as their raw window server values.
  mutating func pack(_ id: WindowID) { pack(id.rawValue) }
  mutating func pack(_ id: SpaceID) { pack(id.rawValue) }

  mutating func message(_ opcode: sa_opcode) -> [UInt8]? {
    if overflow { return nil }
    let length = Int16(bytes.count - 2)
    withUnsafeBytes(of: length) { bytes.replaceSubrange(0..<2, with: $0) }
    bytes[2] = UInt8(opcode.rawValue)
    return bytes
  }

  mutating func send(_ opcode: sa_opcode) -> Bool {
    guard let bytes = message(opcode) else { return false }
    return ScriptingAddition.shared.send(bytes)
  }
}
