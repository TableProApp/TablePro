import Foundation
import Testing

@testable import TablePro

struct BundleAppInfoTests {
    @Test("A numeric CFBundleVersion is the build number")
    func numericBuild() throws {
        try withBundle(["CFBundleVersion": "4790"]) { bundle in
            #expect(bundle.buildNumber == 4_790)
        }
    }

    @Test("A dotted CFBundleVersion gives build 0")
    func dottedBuild() throws {
        try withBundle(["CFBundleVersion": "1.2"]) { bundle in
            #expect(bundle.buildNumber == 0)
        }
    }

    @Test("A missing CFBundleVersion gives build 0")
    func missingBuild() throws {
        try withBundle(["CFBundleShortVersionString": "0.82.0"]) { bundle in
            #expect(bundle.buildNumber == 0)
        }
    }

    @Test("A missing CFBundleShortVersionString gives 0.0.0")
    func missingVersion() throws {
        try withBundle(["CFBundleVersion": "4790"]) { bundle in
            #expect(bundle.appVersion == "0.0.0")
        }
    }

    @Test("A beta version is a prerelease")
    func betaIsPrerelease() throws {
        try withBundle(["CFBundleShortVersionString": "0.82.0-beta.1"]) { bundle in
            #expect(bundle.isPrerelease)
        }
    }

    @Test("A release version is not a prerelease")
    func releaseIsNotPrerelease() throws {
        try withBundle(["CFBundleShortVersionString": "0.82.0"]) { bundle in
            #expect(!bundle.isPrerelease)
        }
    }

    @Test("displayVersion puts the build in parentheses")
    func displayVersion() throws {
        try withBundle(["CFBundleShortVersionString": "0.82.0-beta.1", "CFBundleVersion": "820001"]) { bundle in
            #expect(bundle.displayVersion == "0.82.0-beta.1 (820001)")
        }
    }

    private func withBundle(_ info: [String: String], _ body: (Bundle) throws -> Void) throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("BundleAppInfoTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let bundleURL = root.appendingPathComponent("Probe.bundle", isDirectory: true)
        let contents = bundleURL.appendingPathComponent("Contents", isDirectory: true)
        try FileManager.default.createDirectory(at: contents, withIntermediateDirectories: true)
        let plist = try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
        try plist.write(to: contents.appendingPathComponent("Info.plist"))
        let bundle = try #require(Bundle(url: bundleURL))
        try body(bundle)
    }
}
