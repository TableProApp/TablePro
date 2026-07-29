//
//  PluginManagerStagingCleanupTests.swift
//  TableProTests
//

import Foundation
import Testing
@testable import TablePro

@Suite("PluginManager staging directory cleanup", .serialized)
struct PluginManagerStagingCleanupTests {

    private func makeTempPluginsDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("StagingTests-\(UUID().uuidString)/Plugins", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    @Test("stagingRoot derived path is a sibling of userPluginsDir")
    func stagingRootSibling() throws {
        let userPluginsDir = try makeTempPluginsDir()
        defer { try? FileManager.default.removeItem(at: userPluginsDir.deletingLastPathComponent()) }

        let stagingRoot = PluginInstaller.stagingRoot(for: userPluginsDir)
        #expect(stagingRoot.lastPathComponent == "PluginStaging")
        #expect(stagingRoot.deletingLastPathComponent() == userPluginsDir.deletingLastPathComponent())
    }

    @Test("staging root can be created and populated then enumerated")
    func stagingRootEnumerable() throws {
        let userPluginsDir = try makeTempPluginsDir()
        defer { try? FileManager.default.removeItem(at: userPluginsDir.deletingLastPathComponent()) }

        let stagingRoot = PluginInstaller.stagingRoot(for: userPluginsDir)
        try FileManager.default.createDirectory(at: stagingRoot, withIntermediateDirectories: true)

        let leftover = stagingRoot.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: leftover, withIntermediateDirectories: true)
        try Data("partial".utf8).write(to: leftover.appendingPathComponent("scratch.zip"))

        let contents = try FileManager.default.contentsOfDirectory(
            at: stagingRoot,
            includingPropertiesForKeys: nil
        )
        #expect(!contents.isEmpty)

        for item in contents {
            try FileManager.default.removeItem(at: item)
        }

        let afterCleanup = try FileManager.default.contentsOfDirectory(
            at: stagingRoot,
            includingPropertiesForKeys: nil
        )
        #expect(afterCleanup.isEmpty)
    }
}
