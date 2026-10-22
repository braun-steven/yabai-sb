import Foundation
import Testing
@testable import Yabai

//
// NOTE: The builders of the launchd service (Service.swift) and the messages of its errors. The builders are pure: they
// make strings and argument arrays, and touch neither launchd nor the file system.
//

@Suite struct ServiceTests
{
    static let uid: uid_t = 501
    static let plistPath = "/Users/steven/Library/LaunchAgents/com.asmvik.yabai.plist"
    static let target = "gui/501/com.asmvik.yabai"
    static let domain = "gui/501"

    @Test("the property list keeps the layout of the service file, tabs included")
    func plistLayout()
    {
        let expected = [
            "<?xml version=\"1.0\" encoding=\"UTF-8\"?>",
            "<!DOCTYPE plist PUBLIC \"-//Apple//DTD PLIST 1.0//EN\" \"http://www.apple.com/DTDs/PropertyList-1.0.dtd\">",
            "<plist version=\"1.0\">",
            "<dict>",
            "    <key>Label</key>",
            "    <string>com.asmvik.yabai</string>",
            "    <key>ProgramArguments</key>",
            "    <array>",
            "        <string>/usr/local/bin/yabai</string>",
            "    </array>",
            "    <key>EnvironmentVariables</key>",
            "    <dict>",
            "        <key>PATH</key>",
            "        <string>/usr/bin:/bin</string>",
            "    </dict>",
            "    <key>RunAtLoad</key>",
            "    <true/>",
            "    <key>KeepAlive</key>",
            "    <dict>",
            "        <key>SuccessfulExit</key>",
            " \t     <false/>",
            " \t     <key>Crashed</key>",
            " \t     <true/>",
            "    </dict>",
            "    <key>StandardOutPath</key>",
            "    <string>/tmp/yabai_steven.out.log</string>",
            "    <key>StandardErrorPath</key>",
            "    <string>/tmp/yabai_steven.err.log</string>",
            "    <key>ProcessType</key>",
            "    <string>Interactive</string>",
            "    <key>Nice</key>",
            "    <integer>-20</integer>",
            "</dict>",
            "</plist>",
        ].joined(separator: "\n")

        #expect(Service.plist(executable: "/usr/local/bin/yabai", path: "/usr/bin:/bin", user: "steven") == expected)
    }

    @Test("the property list parses as a property list with the label and the log paths")
    func plistParses() throws
    {
        let contents = Service.plist(executable: "/usr/local/bin/yabai", path: "/usr/bin:/bin", user: "steven")
        let value = try PropertyListSerialization.propertyList(from: Data(contents.utf8), format: nil)
        let dictionary = try #require(value as? [String: Any])

        #expect(dictionary["Label"] as? String == "com.asmvik.yabai")
        #expect(dictionary["ProgramArguments"] as? [String] == ["/usr/local/bin/yabai"])
        #expect(dictionary["StandardOutPath"] as? String == "/tmp/yabai_steven.out.log")
        #expect(dictionary["StandardErrorPath"] as? String == "/tmp/yabai_steven.err.log")
        #expect((dictionary["Nice"] as? Int) == -20)
    }

    @Test("start on an unloaded service enables it and bootstraps it, the last one gives the status")
    func startUnloaded()
    {
        #expect(Service.launchctlArguments(for: .start(isBootstrapped: false), uid: Self.uid, plistPath: Self.plistPath)
            == [["enable", Self.target], ["bootstrap", Self.domain, Self.plistPath]])
    }

    @Test("start on a loaded service kickstarts it")
    func startLoaded()
    {
        #expect(Service.launchctlArguments(for: .start(isBootstrapped: true), uid: Self.uid, plistPath: Self.plistPath)
            == [["kickstart", Self.target]])
    }

    @Test("restart kickstarts the service with -k")
    func restart()
    {
        #expect(Service.launchctlArguments(for: .restart, uid: Self.uid, plistPath: Self.plistPath)
            == [["kickstart", "-k", Self.target]])
    }

    @Test("stop on an unloaded service sends SIGTERM to a running instance")
    func stopUnloaded()
    {
        #expect(Service.launchctlArguments(for: .stop(isBootstrapped: false), uid: Self.uid, plistPath: Self.plistPath)
            == [["kill", "SIGTERM", Self.target]])
    }

    @Test("stop on a loaded service boots it out and then disables it")
    func stopLoaded()
    {
        #expect(Service.launchctlArguments(for: .stop(isBootstrapped: true), uid: Self.uid, plistPath: Self.plistPath)
            == [["bootout", Self.domain, Self.plistPath], ["disable", Self.target]])
    }

    @Test("the targets of the GUI domain of the user")
    func targets()
    {
        #expect(Service.serviceTarget(uid: 0) == "gui/0/com.asmvik.yabai")
        #expect(Service.domainTarget(uid: 0) == "gui/0")
    }

    @Test("the messages of the errors are the texts the commands print")
    func messages()
    {
        #expect(ServiceError.missingEnvironment("USER").message == "'env USER' not set")
        #expect(ServiceError.missingEnvironment("PATH").message == "'env PATH' not set")
        #expect(ServiceError.homeDirectoryUnavailable.message == "unable to retrieve home directory")
        #expect(ServiceError.executablePathUnavailable.message == "unable to retrieve path of executable")
        #expect(ServiceError.alreadyInstalled(path: "/p").message == "service file '/p' is already installed")
        #expect(ServiceError.notInstalled(path: "/p").message == "service file '/p' is not installed")
        #expect(ServiceError.plistNotWritten(path: "/p").message == "service file '/p' could not be installed")
    }
}
