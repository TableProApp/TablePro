//
//  SampleDatabaseServiceTests.swift
//  TableProTests
//

import Foundation
import TableProPluginKit
import Testing

@testable import TablePro

@MainActor
@Suite("SampleDatabaseService install/reset lifecycle")
struct SampleDatabaseServiceTests {
    private static let bundledMarker = Data("BUNDLED-CHINOOK-V1".utf8)

    private final class StubInspector: SampleDatabaseConnectionInspector, @unchecked Sendable {
        var sampleConnectionOpen = false
        func isSampleConnectionOpen(at fileURL: URL) -> Bool { sampleConnectionOpen }
    }

    private struct Harness {
        let service: SampleDatabaseService
        let bundledURL: URL
        let installedURL: URL
        let inspector: StubInspector
        let workingDirectory: URL
    }

    private func makeHarness(skipBundleFile: Bool = false) throws -> Harness {
        let workingDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("SampleDatabaseServiceTests", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(
            at: workingDirectory,
            withIntermediateDirectories: true
        )

        let bundleDirectory = workingDirectory.appendingPathComponent("Bundle", isDirectory: true)
        try FileManager.default.createDirectory(
            at: bundleDirectory,
            withIntermediateDirectories: true
        )
        let bundledURL = bundleDirectory.appendingPathComponent("Chinook.sqlite", isDirectory: false)
        if !skipBundleFile {
            try Self.bundledMarker.write(to: bundledURL)
        }

        let installedDirectory = workingDirectory.appendingPathComponent("Installed", isDirectory: true)
        let installedURL = installedDirectory.appendingPathComponent("Chinook.sqlite", isDirectory: false)
        let inspector = StubInspector()

        let service = SampleDatabaseService(
            bundledFileResolver: { skipBundleFile ? nil : bundledURL },
            fileManager: .default,
            connectionInspector: inspector,
            baseDirectoryProvider: { installedDirectory }
        )

        return Harness(
            service: service,
            bundledURL: bundledURL,
            installedURL: installedURL,
            inspector: inspector,
            workingDirectory: workingDirectory
        )
    }

    @Test("installIfNeeded copies the bundled file when nothing is installed")
    func installIfNeeded_copiesBundledFile_whenInstalledMissing() throws {
        let harness = try makeHarness()
        defer { try? FileManager.default.removeItem(at: harness.workingDirectory) }

        #expect(!FileManager.default.fileExists(atPath: harness.installedURL.path))
        try harness.service.installIfNeeded()

        let installedData = try Data(contentsOf: harness.installedURL)
        #expect(installedData == Self.bundledMarker)
    }

    @Test("installIfNeeded preserves user edits when an installed copy exists")
    func installIfNeeded_preservesEdits_whenInstalledExists() throws {
        let harness = try makeHarness()
        defer { try? FileManager.default.removeItem(at: harness.workingDirectory) }

        try harness.service.installIfNeeded()
        let edited = Data("USER-EDITED".utf8)
        try edited.write(to: harness.installedURL)

        try harness.service.installIfNeeded()

        let installedData = try Data(contentsOf: harness.installedURL)
        #expect(installedData == edited, "Existing installed file must not be overwritten")
    }

    @Test("resetToBundled overwrites the installed file with the bundled copy")
    func resetToBundled_overwritesInstalled() throws {
        let harness = try makeHarness()
        defer { try? FileManager.default.removeItem(at: harness.workingDirectory) }

        try harness.service.installIfNeeded()
        try Data("USER-EDITED".utf8).write(to: harness.installedURL)

        try harness.service.resetToBundled()

        let installedData = try Data(contentsOf: harness.installedURL)
        #expect(installedData == Self.bundledMarker)
    }

    @Test("resetToBundled throws connectionInUse when the sample is open")
    func resetToBundled_throwsConnectionInUse_whenConnectionOpen() throws {
        let harness = try makeHarness()
        defer { try? FileManager.default.removeItem(at: harness.workingDirectory) }

        try harness.service.installIfNeeded()
        harness.inspector.sampleConnectionOpen = true

        #expect(throws: SampleDatabaseError.connectionInUse) {
            try harness.service.resetToBundled()
        }
    }

    @Test("installIfNeeded throws bundleMissing when the bundle has no Chinook file")
    func installIfNeeded_throwsBundleMissing_whenBundleHasNoFile() throws {
        let harness = try makeHarness(skipBundleFile: true)
        defer { try? FileManager.default.removeItem(at: harness.workingDirectory) }

        #expect(throws: SampleDatabaseError.bundleMissing) {
            try harness.service.installIfNeeded()
        }
    }
}
