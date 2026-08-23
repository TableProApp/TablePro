//
//  SidebarRowSizePreferenceTests.swift
//  TableProTests
//

import AppKit
import SwiftUI
@testable import TablePro
import Testing

@Suite("Sidebar row size")
struct SidebarRowSizePreferenceTests {
    @Test("Match System takes whatever size the system reports")
    func matchSystemFollowsTheSystem() {
        #expect(SidebarRowSizeResolver.resolve(preference: .matchSystem, system: .small) == .small)
        #expect(SidebarRowSizeResolver.resolve(preference: .matchSystem, system: .medium) == .medium)
        #expect(SidebarRowSizeResolver.resolve(preference: .matchSystem, system: .large) == .large)
    }

    @Test("An explicit size wins over the system setting")
    func explicitSizeOverridesTheSystem() {
        #expect(SidebarRowSizeResolver.resolve(preference: .small, system: .large) == .small)
        #expect(SidebarRowSizeResolver.resolve(preference: .large, system: .small) == .large)
    }

    /// `.default` is the only `RowSizeStyle` that tracks the Appearance setting, so Match System
    /// has to resolve to it rather than to a size picked at build time.
    @Test("Match System maps to the row size style that follows the system")
    func matchSystemUsesTheDefaultStyle() {
        #expect(SidebarRowSizeResolver.rowSizeStyle(for: .matchSystem) == .default)
    }

    @Test("Each explicit size maps to its own row size style")
    func explicitSizesMapDirectly() {
        #expect(SidebarRowSizeResolver.rowSizeStyle(for: .small) == .small)
        #expect(SidebarRowSizeResolver.rowSizeStyle(for: .medium) == .medium)
        #expect(SidebarRowSizeResolver.rowSizeStyle(for: .large) == .large)
    }

    @Test("A taller row draws larger text and a larger glyph")
    func contentScalesWithTheRow() {
        #expect(SidebarRowSize.small.iconPointSize < SidebarRowSize.medium.iconPointSize)
        #expect(SidebarRowSize.medium.iconPointSize < SidebarRowSize.large.iconPointSize)
    }

    @Test("The preference round-trips through settings so it survives a relaunch")
    func preferenceIsCodable() throws {
        let settings = GeneralSettings(sidebarRowSize: .large)
        let decoded = try JSONDecoder().decode(
            GeneralSettings.self, from: try JSONEncoder().encode(settings)
        )

        #expect(decoded.sidebarRowSize == .large)
    }

    @Test("Settings saved before the preference existed default to following the system")
    func olderSettingsDefaultToMatchSystem() throws {
        let json = Data(#"{"startupBehavior":"reopenLast"}"#.utf8)
        let decoded = try JSONDecoder().decode(GeneralSettings.self, from: json)

        #expect(decoded.sidebarRowSize == .matchSystem)
    }
}
