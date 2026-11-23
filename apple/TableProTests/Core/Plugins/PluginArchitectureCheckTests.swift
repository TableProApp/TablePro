import Foundation
@testable import TablePro
import Testing

struct PluginArchitectureCheckTests {
    private func makeTempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("PluginArchitectureCheckTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    @discardableResult
    private func writeBundle(
        in directory: URL,
        executable: Data?,
        executableName: String? = "Driver",
        build: Int = 820_100
    ) throws -> URL {
        let bundleURL = directory.appendingPathComponent("Driver.tableplugin", isDirectory: true)
        let contents = bundleURL.appendingPathComponent("Contents", isDirectory: true)
        try FileManager.default.createDirectory(at: contents, withIntermediateDirectories: true)
        var info: [String: Any] = [
            "CFBundleIdentifier": "com.example.Driver",
            "CFBundleVersion": String(build),
            "TableProPluginKitVersion": PluginManager.currentPluginKitVersion
        ]
        if let executableName { info["CFBundleExecutable"] = executableName }
        let data = try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
        try data.write(to: contents.appendingPathComponent("Info.plist"))
        if let executable, let executableName {
            try MachOFixture.writeExecutable(executable, named: executableName, into: bundleURL)
        }
        return bundleURL
    }

    @Test("A bundle that names no executable, or whose executable is missing, passes")
    func noExecutablePasses() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let unnamed = try writeBundle(in: dir.appendingPathComponent("a"), executable: nil, executableName: nil)
        let missing = try writeBundle(in: dir.appendingPathComponent("b"), executable: nil)

        try PluginManager.validateArchitecture(at: unnamed)
        try PluginManager.validateArchitecture(at: missing)
    }

    @Test("An executable that is not Mach-O passes, for the loader to report")
    func nonMachOPasses() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let bundle = try writeBundle(in: dir, executable: Data("not a mach-o binary".utf8))

        try PluginManager.validateArchitecture(at: bundle)
    }

    @Test("A thin executable passes only for its own architecture", arguments: [
        MachOFixture.arm64, MachOFixture.x86_64
    ])
    func thinExecutableMatchesItsArchitecture(architecture: Int) throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let other = architecture == MachOFixture.arm64 ? MachOFixture.x86_64 : MachOFixture.arm64

        let bundle = try writeBundle(in: dir, executable: MachOFixture.thin(architecture))

        try PluginManager.validateArchitecture(at: bundle, running: architecture)
        let error = #expect(throws: PluginError.self) {
            try PluginManager.validateArchitecture(at: bundle, running: other)
        }
        guard case .missingArchitecture = error else {
            Issue.record("Expected missingArchitecture, got \(String(describing: error))")
            return
        }
    }

    @Test("A universal executable passes on either architecture", arguments: [
        MachOFixture.arm64, MachOFixture.x86_64
    ])
    func universalExecutablePasses(running: Int) throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let bundle = try writeBundle(in: dir, executable: MachOFixture.fat([MachOFixture.x86_64, MachOFixture.arm64]))

        try PluginManager.validateArchitecture(at: bundle, running: running)
    }

    @Test("A user plugin without this process's architecture fails the bundle check; a built-in one skips it")
    func builtInSkipsTheCheck() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let bundleURL = try writeBundle(in: dir, executable: MachOFixture.thin(MachOFixture.otherArchitecture))
        let bundle = try #require(Bundle(url: bundleURL))

        try PluginManager.validateBundleVersions(bundle, source: .builtIn)
        let error = #expect(throws: PluginError.self) {
            try PluginManager.validateBundleVersions(bundle)
        }
        guard case .missingArchitecture = error else {
            Issue.record("Expected missingArchitecture, got \(String(describing: error))")
            return
        }
    }

    @Test("A plugin replaced in place by a build for this architecture passes at once")
    func inPlaceRepairPassesTheArchitectureCheck() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let bundleURL = try writeBundle(in: dir, executable: MachOFixture.thin(MachOFixture.otherArchitecture), build: 1)
        let cached = try #require(Bundle(url: bundleURL))
        #expect(throws: PluginError.self) { try PluginManager.validateBundleVersions(cached) }

        try writeBundle(in: dir, executable: MachOFixture.thin(PluginManager.runningArchitecture), build: 2)

        try PluginManager.validateBundleVersions(cached)
        try PluginManager.validateBundleVersions(try #require(Bundle(url: bundleURL)))
    }

    @Test("A registry download without this architecture is refused")
    func registryDownloadWithoutTheArchitectureIsRefused() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let bundleURL = try writeBundle(in: dir, executable: MachOFixture.thin(MachOFixture.otherArchitecture))
        let release = RegistryRelease(
            version: "1.0",
            build: 820_100,
            channel: "stable",
            pluginKit: PluginManager.currentPluginKitVersion,
            minimumSystemVersion: "13.0",
            url: "https://x",
            sha256: "deadbeef"
        )

        let bundle = try #require(Bundle(url: bundleURL))
        let error = #expect(throws: PluginError.self) {
            try PluginInstaller.validateBundle(bundle, against: release, pluginId: "com.example.Driver")
        }
        #expect(error?.localizedDescription == PluginBundleLoader.missingArchitectureReason)
    }

    @Test("The error reads as the loader's architecture message and is not an outdated kit")
    func errorDescription() {
        #expect(PluginError.missingArchitecture.errorDescription == PluginBundleLoader.missingArchitectureReason)
        #expect(!PluginError.missingArchitecture.isOutdated)
        #expect(
            PluginBundleLoader.describeLoadFailure(
                NSError(domain: NSCocoaErrorDomain, code: NSExecutableArchitectureMismatchError)
            ) == PluginBundleLoader.missingArchitectureReason
        )
    }

    @Test("A missing architecture is repairable only from the registry; an outdated kit always is")
    func repairableRejections() {
        let outdated = PluginError.pluginOutdated(pluginVersion: 1, requiredVersion: 2)
        #expect(PluginManager.isRepairableRejection(PluginError.missingArchitecture, registryId: "com.example.Driver"))
        #expect(!PluginManager.isRepairableRejection(PluginError.missingArchitecture, registryId: nil))
        #expect(PluginManager.isRepairableRejection(outdated, registryId: nil))
        #expect(!PluginManager.isRepairableRejection(PluginError.checksumMismatch, registryId: "com.example.Driver"))
        #expect(!PluginManager.isRepairableRejection(CocoaError(.fileNoSuchFile), registryId: "com.example.Driver"))
    }
}
