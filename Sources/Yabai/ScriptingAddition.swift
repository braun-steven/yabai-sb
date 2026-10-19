import AppKit
import Darwin
import CPrivate
import OSAX
import YabaiCore

private let saVersion = String(cString: sa_payload_version())

// Ported from src/sa.m. Request fields retain their native integer/float layout. Replies accept
// an optional status byte, and legacy payload EOF remains an explicitly unconfirmed success.

//
// NOTE: The socket of the payload. The daemon sets it at startup (configure_settings_and_acquire_lock), before any
// other thread runs, and --load-sa or --uninstall-sa sets it for the user of sudo before it connects.
//

/// `g_sa_socket_file`
nonisolated(unsafe) var g_sa_socket_file = ""

/// `struct sa_window_order`: a window ordered relative to another one; the payload gets the fields one by one.
struct sa_window_order
{
    var a_wid: WindowID
    var order: Int32
    var b_wid: WindowID?
}

private enum SAPath
{
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

private func scriptingAdditionCreateDirectory() -> Bool
{
    for path in [SAPath.base, SAPath.contents, SAPath.macOS, SAPath.resources, SAPath.payload, SAPath.payloadContents, SAPath.payloadMacOS] {
        if mkdir(path, 0o755) != 0 { return false }
    }
    return true
}

private func scriptingAdditionWriteFile(_ bytes: UnsafeRawPointer?, _ size: Int, _ path: String, _ mode: String) -> Bool
{
    guard let handle = fopen(path, mode) else { return false }
    let result = fwrite(bytes, size, 1, handle) == 1
    return fclose(handle) == 0 && result
}

private func scriptingAdditionWriteFile(_ text: String, _ path: String) -> Bool
{
    text.withCString { scriptingAdditionWriteFile($0, text.utf8.count, path, "w") }
}

private func scriptingAdditionPrepareBinaries() -> Bool
{
    for path in [SAPath.loaderBinary, SAPath.payloadBinary] {
        guard chmod(path, 0o755) == 0, SystemC("/usr/bin/codesign -f -s - \(path)") == 0 else { return false }
    }
    return true
}

/// `sa_notify`
private func sa_notify(_ text: String)
{
    notify("scripting-addition", text)
}

private func scriptingAdditionRestartDock()
{
    for dock in NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.dock") { dock.terminate() }
}

private func scriptingAdditionSetSocketPath() -> Bool
{
    assert(getuid() == 0)
    guard let value = getenv("SUDO_UID") else { return false }
    var uid: uid_t = 0
    let parsed = sscanfUIntC(value, &uid)
    guard parsed == 1, let pw = getpwuid(uid), let name = pw.pointee.pw_name else { return false }
    let path = "/tmp/yabai-sa_\(String(cString: name)).socket"
    g_sa_socket_file = path
    return true
}

private func scriptingAdditionIsInstalled() -> Bool
{
    guard let dir = opendir(SAPath.base) else { return false }
    closedir(dir)
    return true
}

private func scriptingAdditionCheck() -> Int32
{
    autoreleasepool {
        guard scriptingAdditionIsInstalled(), let bundle = Bundle(path: SAPath.payload),
              let version = bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String else { return 1 }
        return version.utf8.elementsEqual(saVersion.utf8) ? 0 : 1
    }
}

@discardableResult private func scriptingAdditionRemove() -> Bool
{
    SystemC("rm -rf \(SAPath.base) 2>/dev/null") == 0
}

private func scriptingAdditionInstall() -> Int32
{
    let previousMask = umask(mode_t(S_IWGRP | S_IWOTH))
    defer { umask(previousMask) }
    if scriptingAdditionIsInstalled() && !scriptingAdditionRemove() { return 1 }
    guard scriptingAdditionCreateDirectory(),
          scriptingAdditionWriteFile(saPlist, SAPath.info),
          scriptingAdditionWriteFile(saBundlePlist, SAPath.payloadInfo),
          scriptingAdditionWriteFile(sa_loader_bytes(), Int(sa_loader_size()), SAPath.loaderBinary, "wb"),
          scriptingAdditionWriteFile(sa_payload_bytes(), Int(sa_payload_size()), SAPath.payloadBinary, "wb"),
          scriptingAdditionPrepareBinaries() else {
        scriptingAdditionRemove()
        return 2
    }
    scriptingAdditionRestartDock()
    return 0
}

private func scriptingAdditionRequestHandshake() -> (version: [UInt8], attributes: UInt32)?
{
    var sockfd: Int32 = 0
    guard socket_open(&sockfd) else { return nil }
    defer { socket_close(sockfd) }
    guard let connection = SAConnection(fd: sockfd), connection.connect(g_sa_socket_file) else { return nil }
    return connection.handshake()
}

private func scriptingAdditionPerformValidation() -> Int32
{
    let isLatestInstalled = scriptingAdditionCheck() == 0
    guard let handshake = scriptingAdditionRequestHandshake() else { sa_notify("connection failed!"); return 1 }
    if handshake.version.elementsEqual(saVersion.utf8) {
        // OSAX_ATTRIB_ALL (the macro combines macros and does not import).
        let all = UInt32(OSAX_ATTRIB_DOCK_SPACES | OSAX_ATTRIB_DPPM | OSAX_ATTRIB_ADD_SPACE | OSAX_ATTRIB_REM_SPACE | OSAX_ATTRIB_MOV_SPACE | OSAX_ATTRIB_ANIM_TIME)
        if handshake.attributes & all == all {
            sa_notify("payload v\(String(decoding: handshake.version, as: UTF8.self))")
            return 0
        }
        sa_notify("payload (0x\(String(handshake.attributes, radix: 16, uppercase: true))) doesn't support this macOS version!")
        return 1
    }
    if !isLatestInstalled {
        sa_notify("payload is outdated, updating..")
        return scriptingAdditionInstall()
    }
    sa_notify("payload is outdated, restarting Dock.app..")
    scriptingAdditionRestartDock()
    return 0
}

func scripting_addition_is_sip_friendly() -> Bool
{
    var config: UInt32 = 0
    csr_get_active_config(&config)
    return config & 0x02 != 0 && config & 0x04 != 0 // CSR_ALLOW_UNRESTRICTED_FS, CSR_ALLOW_TASK_FOR_PID
}

private func scriptingAdditionIsArm64eEnabled() -> Bool
{
    var args = [CChar](repeating: 0, count: 2048)
    var length = args.count - 1
    return sysctlbyname("kern.bootargs", &args, &length, nil, 0) == 0 && strnstr(args, "-arm64e_preview_abi", length) != nil
}

private func machLoaderInjectPayload() -> Bool
{
    guard let handle = PopenC(SAPath.loaderBinary, "r") else { return false }
    let result = PcloseC(handle)
    // WIFEXITED and WEXITSTATUS are function-like macros, unavailable to Swift.
    return result & 0x7f == 0 && (result >> 8) & 0xff == 0
}

func scripting_addition_uninstall() -> Int32
{
    if !scripting_addition_is_sip_friendly() {
        Client.writeAll(STDERR_FILENO, "yabai: System Integrity Protection: Filesystem Protections and Debugging Restrictions must be disabled!\n".utf8)
        sa_notify("System Integrity Protection: Filesystem Protections and Debugging Restrictions must be disabled!")
        return 1
    }
    if !is_root() {
        Client.writeAll(STDERR_FILENO, "yabai: scripting-addition must be uninstalled as root!\n".utf8)
        sa_notify("must be uninstalled as root!")
        return 1
    }
    if !scriptingAdditionIsInstalled() { return 0 }
    return scriptingAdditionRemove() ? 0 : -1
}

func scripting_addition_load() -> Int32
{
    autoreleasepool {
        if !is_root() {
            Client.writeAll(STDERR_FILENO, "yabai: scripting-addition must be loaded as root!\n".utf8)
            sa_notify("must be loaded as root!")
            return 1
        }
        if !scripting_addition_is_sip_friendly() {
            Client.writeAll(STDERR_FILENO, "yabai: System Integrity Protection: Filesystem Protections and Debugging Restrictions must be disabled!\n".utf8)
            sa_notify("System Integrity Protection: Filesystem Protections and Debugging Restrictions must be disabled!")
            return 1
        }
        if scriptingAdditionCheck() != 0 { return scriptingAdditionInstall() }
        if !scriptingAdditionIsArm64eEnabled() {
            Client.writeAll(STDERR_FILENO, "yabai: missing required nvram boot-arg '-arm64e_preview_abi'!\n".utf8)
            sa_notify("missing required nvram boot-arg '-arm64e_preview_abi'!")
            return 1
        }
        guard scriptingAdditionSetSocketPath() else {
            Client.writeAll(STDERR_FILENO, "yabai: cannot determine the scripting-addition user from SUDO_UID!\n".utf8)
            return 1
        }
        if !machLoaderInjectPayload() {
            Client.writeAll(STDERR_FILENO, "yabai: scripting-addition failed to inject payload into Dock.app!\n".utf8)
            sa_notify("failed to inject payload into Dock.app!")
            return 1
        }
        return scriptingAdditionPerformValidation()
    }
}

//
// NOTE: A payload that does not fit the buffer (e.g. a very long window list) is not sent, and the
// operation reports failure so that the caller can fall back, instead of overflowing the stack buffer.
//

struct SAPayload
{
    private(set) var bytes: [UInt8] = [0, 0, 0]
    private(set) var overflow = false

    mutating func pack<T>(_ value: T)
    {
        if bytes.count + MemoryLayout<T>.size > Int(SA_SOCKET_BUFF_LEN) { overflow = true; return }
        withUnsafeBytes(of: value) { bytes.append(contentsOf: $0) }
    }

    /// The payload carries ids as their raw window server values.
    mutating func pack(_ id: WindowID) { pack(id.rawValue) }
    mutating func pack(_ id: SpaceID) { pack(id.rawValue) }

    mutating func message(_ opcode: sa_opcode) -> [UInt8]?
    {
        if overflow { return nil }
        let length = Int16(bytes.count - 2)
        withUnsafeBytes(of: length) { bytes.replaceSubrange(0..<2, with: $0) }
        bytes[2] = UInt8(opcode.rawValue)
        return bytes
    }

    mutating func send(_ opcode: sa_opcode) -> Bool
    {
        guard let bytes = message(opcode) else { return false }
        return scriptingAdditionSendBytes(bytes)
    }
}

private func scriptingAdditionSendBytes(_ bytes: [UInt8]) -> Bool
{
    var sockfd: Int32 = 0
    guard socket_open(&sockfd) else { return false }
    defer { socket_close(sockfd) }
    guard let connection = SAConnection(fd: sockfd), connection.connect(g_sa_socket_file) else { return false }
    return connection.command(bytes).isSuccess
}

@discardableResult func scripting_addition_focus_space(_ sid: SpaceID) -> Bool
{
    var payload = SAPayload(); payload.pack(sid)
    return payload.send(SA_OPCODE_SPACE_FOCUS)
}

@discardableResult func scripting_addition_create_space(_ sid: SpaceID) -> Bool
{
    var payload = SAPayload(); payload.pack(sid)
    return payload.send(SA_OPCODE_SPACE_CREATE)
}

@discardableResult func scripting_addition_destroy_space(_ sid: SpaceID) -> Bool
{
    var payload = SAPayload(); payload.pack(sid)
    return payload.send(SA_OPCODE_SPACE_DESTROY)
}

@discardableResult func scripting_addition_move_space_to_display(_ srcSid: SpaceID, _ dstSid: SpaceID, _ srcPrevSid: SpaceID?, _ focus: Bool) -> Bool
{
    var payload = SAPayload(); payload.pack(srcSid); payload.pack(dstSid); payload.pack(srcPrevSid?.rawValue ?? 0); payload.pack(focus)
    return payload.send(SA_OPCODE_SPACE_MOVE)
}

@discardableResult func scripting_addition_move_space_after_space(_ srcSid: SpaceID, _ dstSid: SpaceID, _ focus: Bool) -> Bool
{
    scripting_addition_move_space_to_display(srcSid, dstSid, nil, focus)
}

@discardableResult func scripting_addition_move_window(_ wid: WindowID, _ x: Int32, _ y: Int32) -> Bool
{
    var payload = SAPayload(); payload.pack(wid); payload.pack(x); payload.pack(y)
    return payload.send(SA_OPCODE_WINDOW_MOVE)
}

@discardableResult func scripting_addition_set_opacity(_ wid: WindowID, _ opacity: Float, _ duration: Float) -> Bool
{
    var payload = SAPayload(); payload.pack(wid); payload.pack(opacity); payload.pack(duration)
    return payload.send(duration > 0 ? SA_OPCODE_WINDOW_OPACITY_FADE : SA_OPCODE_WINDOW_OPACITY)
}

@discardableResult func scripting_addition_set_layer(_ wid: WindowID, _ layer: Int32) -> Bool
{
    var payload = SAPayload(); payload.pack(wid); payload.pack(layer)
    return payload.send(SA_OPCODE_WINDOW_LAYER)
}

@discardableResult func scripting_addition_set_sticky(_ wid: WindowID, _ sticky: Bool) -> Bool
{
    var payload = SAPayload(); payload.pack(wid); payload.pack(sticky)
    return payload.send(SA_OPCODE_WINDOW_STICKY)
}

@discardableResult func scripting_addition_set_shadow(_ wid: WindowID, _ shadow: Bool) -> Bool
{
    var payload = SAPayload(); payload.pack(wid); payload.pack(shadow)
    return payload.send(SA_OPCODE_WINDOW_SHADOW)
}

@discardableResult func scripting_addition_focus_window(_ wid: WindowID) -> Bool
{
    var payload = SAPayload(); payload.pack(wid)
    return payload.send(SA_OPCODE_WINDOW_FOCUS)
}

@discardableResult func scripting_addition_scale_window(_ wid: WindowID, _ x: Float, _ y: Float, _ w: Float, _ h: Float) -> Bool
{
    var payload = SAPayload(); payload.pack(wid); payload.pack(x); payload.pack(y); payload.pack(w); payload.pack(h)
    return payload.send(SA_OPCODE_WINDOW_SCALE)
}

@discardableResult func scripting_addition_swap_window_proxy_in(_ animations: [WindowAnimation]) -> Bool
{
    var payload = SAPayload(); payload.pack(Int32(animations.count))
    for animation in animations {
        payload.pack(animation.skip ? 0 : animation.wid.rawValue)
        if !animation.skip { payload.pack(animation.proxy.id) }
    }
    return payload.send(SA_OPCODE_WINDOW_SWAP_PROXY_IN)
}

@discardableResult func scripting_addition_swap_window_proxy_out(_ animations: [WindowAnimation]) -> Bool
{
    var payload = SAPayload(); payload.pack(Int32(animations.count))
    for animation in animations {
        payload.pack(animation.skip ? 0 : animation.wid.rawValue)
        if !animation.skip { payload.pack(animation.proxy.id) }
    }
    return payload.send(SA_OPCODE_WINDOW_SWAP_PROXY_OUT)
}

@discardableResult func scripting_addition_order_window(_ aWid: WindowID, _ order: Int32, _ bWid: WindowID?) -> Bool
{
    var payload = SAPayload(); payload.pack(aWid); payload.pack(order); payload.pack(bWid?.rawValue ?? 0)
    return payload.send(SA_OPCODE_WINDOW_ORDER)
}

//
// NOTE: A daemon can talk to the payload of an older yabai until Dock is restarted, and an older
// payload ignores opcodes it does not know. Whether the payload is current is asked once with a
// handshake and remembered until Dock restarts. An outdated payload gets one message per window.
//

@WM private var saPayloadCurrent = -1

/// `scripting_addition_payload_changed`
func scripting_addition_payload_changed()
{
    WM.assumeIsolated { saPayloadCurrent = -1 }
}

@WM private func scriptingAdditionPayloadIsCurrent() -> Bool
{
    if saPayloadCurrent == -1, let handshake = scriptingAdditionRequestHandshake() {
        saPayloadCurrent = handshake.version.elementsEqual(saVersion.utf8) ? 1 : 0
    }
    return saPayloadCurrent == 1
}

@discardableResult func scripting_addition_order_window_list(_ list: [sa_window_order]) -> Bool
{
    if list.isEmpty { return true }
    // NOTE: The tree calls this synchronously on the event-loop queue, which owns the handshake cache.
    if !WM.assumeIsolated({ scriptingAdditionPayloadIsCurrent() }) {
        var result = true
        for entry in list { result = scripting_addition_order_window(entry.a_wid, entry.order, entry.b_wid) && result }
        return result
    }
    var result = true
    for offset in stride(from: 0, to: list.count, by: 256) { // SA_WINDOW_ORDER_CHUNK
        let chunk = list[offset..<min(offset + 256, list.count)]
        var payload = SAPayload(); payload.pack(Int32(chunk.count))
        for entry in chunk { payload.pack(entry.a_wid); payload.pack(entry.order); payload.pack(entry.b_wid?.rawValue ?? 0) }
        result = payload.send(SA_OPCODE_WINDOW_ORDER_LIST) && result
    }
    return result
}

@discardableResult func scripting_addition_order_window_in(_ windows: [WindowID]) -> Bool
{
    var orderedIn: UInt8 = 0
    var payload = SAPayload(); payload.pack(Int32(windows.count))
    for wid in windows {
        SLSWindowIsOrderedIn(connection_global(), wid.rawValue, &orderedIn)
        payload.pack(orderedIn != 0 ? 0 : wid.rawValue)
    }
    return payload.send(SA_OPCODE_WINDOW_ORDER_IN)
}

@discardableResult func scripting_addition_move_window_list_to_space(_ sid: SpaceID, _ windows: [WindowID]) -> Bool
{
    var payload = SAPayload(); payload.pack(sid); payload.pack(Int32(windows.count))
    for wid in windows { payload.pack(wid) }
    return payload.send(SA_OPCODE_WINDOW_LIST_TO_SPACE)
}

@discardableResult func scripting_addition_move_window_to_space(_ sid: SpaceID, _ wid: WindowID) -> Bool
{
    var payload = SAPayload(); payload.pack(sid); payload.pack(wid)
    return payload.send(SA_OPCODE_WINDOW_TO_SPACE)
}
