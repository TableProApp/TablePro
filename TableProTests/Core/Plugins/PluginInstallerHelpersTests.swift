import Darwin
import Foundation
import Testing
@testable import TablePro

private final class ChunkedDownloadProtocol: URLProtocol, @unchecked Sendable {
    static let payload = Data(repeating: 7, count: 256 * 1024)

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}

    override func startLoading() {
        guard let url = request.url else { return }
        let headers = url.lastPathComponent == "sized.zip" ? ["Content-Length": "\(Self.payload.count)"] : [:]
        guard let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: headers) else {
            return
        }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        let chunk = Self.payload.count / 8
        for offset in stride(from: 0, to: Self.payload.count, by: chunk) {
            client?.urlProtocol(self, didLoad: Self.payload.subdata(in: offset..<min(offset + chunk, Self.payload.count)))
        }
        client?.urlProtocolDidFinishLoading(self)
    }
}

private actor FractionRecorder {
    private(set) var fractions: [Double] = []

    func record(_ fraction: Double) {
        fractions.append(fraction)
    }
}

struct PluginInstallerHelpersTests {

    private func makeTempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("PluginInstallerTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func makeFakeBundle(at directory: URL, name: String) throws -> URL {
        let bundle = directory.appendingPathComponent("\(name).tableplugin", isDirectory: true)
        try FileManager.default.createDirectory(at: bundle, withIntermediateDirectories: true)
        let contents = bundle.appendingPathComponent("Contents", isDirectory: true)
        try FileManager.default.createDirectory(at: contents, withIntermediateDirectories: true)
        let plist = contents.appendingPathComponent("Info.plist")
        let payload = """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0">
        <dict>
            <key>CFBundleIdentifier</key><string>com.example.\(name)</string>
            <key>TableProPluginKitVersion</key><integer>13</integer>
        </dict>
        </plist>
        """
        try payload.write(to: plist, atomically: true, encoding: .utf8)
        return bundle
    }

    @Test("atomicReplace moves staged bundle into place when destination empty")
    func atomicReplaceCreatesDestination() throws {
        let stagingDir = try makeTempDir()
        let destDir = try makeTempDir()
        defer {
            try? FileManager.default.removeItem(at: stagingDir)
            try? FileManager.default.removeItem(at: destDir)
        }

        let staged = try makeFakeBundle(at: stagingDir, name: "Driver")
        let dest = destDir.appendingPathComponent("Driver.tableplugin", isDirectory: true)

        let final = try PluginInstaller.atomicReplace(stagedBundleURL: staged, destURL: dest)
        #expect(FileManager.default.fileExists(atPath: final.path))
    }

    @Test("atomicReplace overwrites existing destination and removes backup")
    func atomicReplaceOverwritesExisting() throws {
        let stagingDir = try makeTempDir()
        let destDir = try makeTempDir()
        defer {
            try? FileManager.default.removeItem(at: stagingDir)
            try? FileManager.default.removeItem(at: destDir)
        }

        let dest = try makeFakeBundle(at: destDir, name: "Driver")
        let staged = try makeFakeBundle(at: stagingDir, name: "Driver")

        let final = try PluginInstaller.atomicReplace(stagedBundleURL: staged, destURL: dest)
        #expect(FileManager.default.fileExists(atPath: final.path))

        let backupURL = destDir.appendingPathComponent("Driver.tableplugin.bak")
        #expect(!FileManager.default.fileExists(atPath: backupURL.path))
    }

    @Test("stripQuarantine removes the xattr without raising on missing attr")
    func stripQuarantineHandlesMissingAttr() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let bundle = try makeFakeBundle(at: dir, name: "Driver")
        PluginInstaller.stripQuarantine(at: bundle)
        PluginInstaller.stripQuarantine(at: bundle)
    }

    private func makeBundle(in directory: URL, kitVersion: Int?) throws -> Bundle {
        let bundleURL = directory.appendingPathComponent("Kit.tableplugin", isDirectory: true)
        let contents = bundleURL.appendingPathComponent("Contents", isDirectory: true)
        try FileManager.default.createDirectory(at: contents, withIntermediateDirectories: true)
        let kitEntry = kitVersion.map { "<key>TableProPluginKitVersion</key><integer>\($0)</integer>" } ?? ""
        let payload = """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0">
        <dict>
            <key>CFBundleIdentifier</key><string>com.example.Kit</string>
            \(kitEntry)
        </dict>
        </plist>
        """
        try payload.write(to: contents.appendingPathComponent("Info.plist"), atomically: true, encoding: .utf8)
        return try #require(Bundle(url: bundleURL))
    }

    @Test("validateBundleVersions refuses a bundle with no PluginKit version")
    func bundleVersionsRejectsMissingKey() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let bundle = try makeBundle(in: dir, kitVersion: nil)
        let error = #expect(throws: PluginError.self) { try PluginManager.validateBundleVersions(bundle) }
        #expect(error?.isOutdated == true)
    }

    @Test("validateBundleVersions refuses a bundle built for a newer PluginKit")
    func bundleVersionsRejectsNewerKit() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let bundle = try makeBundle(in: dir, kitVersion: PluginManager.currentPluginKitVersion + 1)
        let error = #expect(throws: PluginError.self) { try PluginManager.validateBundleVersions(bundle) }
        guard case .incompatibleVersion(let required, let current) = error else {
            Issue.record("Expected incompatibleVersion, got \(String(describing: error))")
            return
        }
        #expect(required == PluginManager.currentPluginKitVersion + 1)
        #expect(current == PluginManager.currentPluginKitVersion)
    }

    @Test("validateBundleVersions refuses a bundle below the PluginKit floor")
    func bundleVersionsRejectsKitBelowFloor() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let bundle = try makeBundle(in: dir, kitVersion: PluginManager.minimumCompatiblePluginKitVersion - 1)
        let error = #expect(throws: PluginError.self) { try PluginManager.validateBundleVersions(bundle) }
        #expect(error?.isOutdated == true)
    }

    @Test("validateBundleVersions accepts the current PluginKit and the floor", arguments: [
        PluginManager.currentPluginKitVersion,
        PluginManager.minimumCompatiblePluginKitVersion
    ])
    func bundleVersionsAcceptsSupportedKit(kitVersion: Int) throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let bundle = try makeBundle(in: dir, kitVersion: kitVersion)
        try PluginManager.validateBundleVersions(bundle)
    }

    @Test("isCompatibleKit accepts the floor through the current kit and nothing outside it")
    func compatibleKitRange() {
        let minimumKit = PluginManager.minimumCompatiblePluginKitVersion
        let currentKit = PluginManager.currentPluginKitVersion

        #expect(PluginManager.isCompatibleKit(minimumKit))
        #expect(PluginManager.isCompatibleKit(currentKit))
        #expect(!PluginManager.isCompatibleKit(minimumKit - 1))
        #expect(!PluginManager.isCompatibleKit(currentKit + 1))
    }

    private func download(_ name: String) async throws -> (data: Data, fractions: [Double]) {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [ChunkedDownloadProtocol.self]
        let session = URLSession(configuration: config)
        defer { session.finishTasksAndInvalidate() }
        let recorder = FractionRecorder()
        let url = try #require(URL(string: "https://plugins.example.invalid/\(name)"))
        let (file, _) = try await PluginInstaller.download(url, with: session) { fraction in
            await recorder.record(fraction)
        }
        defer { try? FileManager.default.removeItem(at: file) }
        return (try Data(contentsOf: file), await recorder.fractions)
    }

    @Test("download reports the task's own progress and ends at 1")
    func downloadReportsTaskProgress() async throws {
        let (data, fractions) = try await download("sized.zip")

        #expect(data == ChunkedDownloadProtocol.payload)
        #expect(fractions.contains { $0 < 1 })
        #expect(fractions.last == 1)
        #expect(fractions.allSatisfy { $0 > 0 && $0 <= 1 })
        #expect(zip(fractions, fractions.dropFirst()).allSatisfy { $0 <= $1 })
    }

    @Test("download reports no fraction until the end when the length is unknown")
    func downloadWithoutLengthStaysIndeterminate() async throws {
        let (data, fractions) = try await download("unsized.zip")

        #expect(data == ChunkedDownloadProtocol.payload)
        #expect(fractions == [1])
    }

    @Test("findBundle returns the single .tableplugin in a directory")
    func findBundleReturnsSingle() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let bundle = try makeFakeBundle(at: dir, name: "Driver")
        let found = try PluginInstaller.findBundle(in: dir)
        #expect(found.lastPathComponent == bundle.lastPathComponent)
    }

    @Test("findBundle throws when no .tableplugin found")
    func findBundleThrowsWhenEmpty() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        #expect(throws: PluginError.self) {
            _ = try PluginInstaller.findBundle(in: dir)
        }
    }

    @Test("stagingRoot is a sibling of userPluginsDir for same-volume atomic replace")
    func stagingRootIsSiblingOfUserPluginsDir() {
        let userPluginsDir = URL(fileURLWithPath: "/Users/test/Library/Application Support/TablePro/Plugins")
        let stagingRoot = PluginInstaller.stagingRoot(for: userPluginsDir)
        #expect(stagingRoot.deletingLastPathComponent() == userPluginsDir.deletingLastPathComponent())
        #expect(stagingRoot.lastPathComponent == "PluginStaging")
    }
}
