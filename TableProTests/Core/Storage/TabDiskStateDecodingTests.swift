//
//  TabDiskStateDecodingTests.swift
//  TableProTests
//

import Foundation
@testable import TablePro
import Testing

@Suite("TabDiskState decoding")
struct TabDiskStateDecodingTests {
    @Test("Drops tabs with an unknown legacy tab type and keeps the valid ones")
    func dropsUnknownLegacyTabType() throws {
        let queryTab = PersistedTab(
            id: UUID(),
            title: "My Query",
            query: "SELECT 1",
            tabType: .query,
            tableName: nil
        )
        let encoded = try JSONEncoder().encode(TabDiskState(tabs: [queryTab], selectedTabId: queryTab.id))

        let object = try JSONSerialization.jsonObject(with: encoded)
        var json = try #require(object as? [String: Any])
        let validTab = try #require((json["tabs"] as? [[String: Any]])?.first)
        var legacyTab = validTab
        legacyTab["tabType"] = ["terminal": [String: Any]()]
        json["tabs"] = [legacyTab, validTab]

        let mutated = try JSONSerialization.data(withJSONObject: json)
        let decoded = try JSONDecoder().decode(TabDiskState.self, from: mutated)

        #expect(decoded.tabs.count == 1)
        #expect(decoded.tabs.first?.tabType == .query)
    }
}
