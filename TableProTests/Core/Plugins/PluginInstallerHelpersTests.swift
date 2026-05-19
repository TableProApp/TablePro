//
//  PluginInstallerHelpersTests.swift
//  TableProTests
//

import Darwin
import Foundation
import Testing
@testable import TablePro

@Suite("PluginInstaller helpers", .serialized)
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

    @Test("validateStagedABI rejects bundle missing TableProPluginKitVersion")
    func validateStagedABIRejectsMissingKey() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let bundle = dir.appendingPathComponent("Bad.tableplugin", isDirectory: true)
        try FileManager.default.createDirectory(at: bundle, withIntermediateDirectories: true)
        let contents = bundle.appendingPathComponent("Contents", isDirectory: true)
        try FileManager.default.createDirectory(at: contents, withIntermediateDirectories: true)
        let emptyPlist = """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0">
        <dict/>
        </plist>
        """
        try emptyPlist.write(to: contents.appendingPathComponent("Info.plist"), atomically: true, encoding: .utf8)

        #expect(throws: PluginError.self) {
            try PluginInstaller.validateStagedABI(bundleURL: bundle, currentKit: 13, currentInspector: 1)
        }
    }

    @Test("validateStagedABI passes when plist matches current kit version")
    func validateStagedABIPassesMatch() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let bundle = try makeFakeBundle(at: dir, name: "Driver")
        try PluginInstaller.validateStagedABI(bundleURL: bundle, currentKit: 13, currentInspector: 1)
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
