//
//  PluginInstallerCoalescingTests.swift
//  TableProTests
//

import Foundation
import Testing
@testable import TablePro

@Suite("PluginInstaller staged-update bookkeeping", .serialized)
struct PluginInstallerCoalescingTests {

    @Test("hasStagedUpdate returns false for unknown pluginId")
    func unknownStagedUpdate() async {
        let installer = PluginInstaller.shared
        let unknown = await installer.hasStagedUpdate(pluginId: "com.nonexistent.plugin.\(UUID().uuidString)")
        #expect(unknown == false)
    }

    @Test("discardStagedUpdate is safe on unknown pluginId")
    func discardUnknownIsSafe() async {
        let installer = PluginInstaller.shared
        await installer.discardStagedUpdate(pluginId: "com.nonexistent.plugin.\(UUID().uuidString)")
    }

    @Test("stagedURL returns nil for unknown pluginId")
    func unknownStagedURL() async {
        let installer = PluginInstaller.shared
        let url = await installer.stagedURL(for: "com.nonexistent.plugin.\(UUID().uuidString)")
        #expect(url == nil)
    }
}
