//
//  SettingsPaneSearchTests.swift
//  TableProTests
//

import Foundation
@testable import TablePro
import Testing

@Suite("SettingsPane search")
struct SettingsPaneSearchTests {
    @Test("Matches on the pane title")
    func matchesTitle() {
        #expect(SettingsPane.data.matches("data"))
        #expect(SettingsPane.appearance.matches("appear"))
        #expect(SettingsPane.mcp.matches("integrations"))
    }

    @Test("Matches on keywords")
    func matchesKeyword() {
        #expect(SettingsPane.data.matches("pagination"))
        #expect(SettingsPane.data.matches("json viewer"))
        #expect(SettingsPane.sidebar.matches("recent"))
        #expect(SettingsPane.account.matches("icloud"))
        #expect(SettingsPane.editor.matches("vim"))
    }

    @Test("Does not match unrelated queries")
    func noMatchForUnrelated() {
        #expect(!SettingsPane.keyboard.matches("pagination"))
        #expect(!SettingsPane.plugins.matches("vim"))
    }
}
