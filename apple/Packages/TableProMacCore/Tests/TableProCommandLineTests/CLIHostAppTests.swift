import AppKit
import Foundation
@testable import TableProCommandLine
import Testing

struct CLIHostAppTests {
    @Test("Opening targets keeps the shell environment and activates the app")
    func launchKeepsInheritedEnvironment() {
        let environment = ["TABLEPRO_UI_TEST_SANDBOX": "/tmp/tablepro-cli-test", "PATH": "/usr/bin:/bin"]

        let configuration = CLILive.launchConfiguration(environment: environment)

        #expect(configuration.environment == environment)
        #expect(configuration.activates)
    }

    private func fakeApp() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("cli-host-\(UUID().uuidString)", isDirectory: true)
        let app = root.appendingPathComponent("Some Copy.app", isDirectory: true)
        let macOS = app.appendingPathComponent("Contents/MacOS", isDirectory: true)
        try FileManager.default.createDirectory(at: macOS, withIntermediateDirectories: true)
        let info: [String: Any] = [
            "CFBundleIdentifier": "com.example.fake-tablepro",
            "CFBundleShortVersionString": "9.8.7",
            "CFBundleExecutable": "TablePro",
            "CFBundlePackageType": "APPL"
        ]
        let plist = try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
        try plist.write(to: app.appendingPathComponent("Contents/Info.plist"))
        FileManager.default.createFile(atPath: macOS.appendingPathComponent("tablepro-cli").path, contents: Data())
        return app
    }

    @Test("A helper in Contents/MacOS belongs to that app and reports its version")
    func helperInsideAnApp() throws {
        let app = try fakeApp()
        defer { try? FileManager.default.removeItem(at: app.deletingLastPathComponent()) }
        let host = CLIHostApp(executablePath: app.appendingPathComponent("Contents/MacOS/tablepro-cli").path)
        #expect(host.url?.resolvingSymlinksInPath().path == app.resolvingSymlinksInPath().path)
        #expect(host.version == "9.8.7")
        #expect(host.bundleIdentifier == "com.example.fake-tablepro")
        #expect(host.versionLine == "tablepro 9.8.7")
    }

    @Test("A tool anywhere else has no app to open, even inside another app")
    func helperOutsideContentsMacOS() throws {
        let app = try fakeApp()
        defer { try? FileManager.default.removeItem(at: app.deletingLastPathComponent()) }
        #expect(CLIHostApp(executablePath: app.appendingPathComponent("Contents/Developer/usr/bin/xctest").path).url == nil)
        #expect(CLIHostApp(executablePath: "/usr/local/bin/tablepro-cli").url == nil)
        #expect(CLIHostApp(executablePath: nil).versionLine == "tablepro unknown")
    }
}
