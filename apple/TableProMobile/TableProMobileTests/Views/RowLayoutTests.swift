import Foundation
import SwiftUI
import TableProModels
@testable import TableProMobile
import Testing
import UIKit

struct RowLayoutTests {
    @Test("With no choice made, iPhone keeps the cards and every other device opens the grid")
    func defaultFollowsIdiom() {
        #expect(RowLayout.resolved(preferred: nil, idiom: .phone) == .cards)
        #expect(RowLayout.resolved(preferred: nil, idiom: .pad) == .grid)
        #expect(RowLayout.resolved(preferred: nil, idiom: .mac) == .grid)
    }

    @Test("A choice the user made wins on every device", arguments: RowLayout.allCases)
    func choiceWinsOnEveryDevice(layout: RowLayout) {
        for idiom in [UIUserInterfaceIdiom.phone, .pad, .mac] {
            #expect(RowLayout.resolved(preferred: layout, idiom: idiom) == layout)
        }
    }

    @Test("A stored choice is read back by a later browser")
    func storedChoiceIsRemembered() throws {
        let suite = "RowLayoutTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }

        let writer = AppStorage<RowLayout?>(AppPreferences.rowLayoutKey, store: defaults)
        #expect(writer.wrappedValue == nil)
        writer.wrappedValue = .grid

        let reader = AppStorage<RowLayout?>(AppPreferences.rowLayoutKey, store: defaults)
        #expect(reader.wrappedValue == .grid)
        #expect(defaults.string(forKey: AppPreferences.rowLayoutKey) == "grid")
    }

    @Test("An unknown stored value falls back to the device default")
    func unknownStoredValueIsIgnored() throws {
        let suite = "RowLayoutTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set("table", forKey: AppPreferences.rowLayoutKey)

        let stored = AppStorage<RowLayout?>(AppPreferences.rowLayoutKey, store: defaults).wrappedValue
        #expect(stored == nil)
        #expect(RowLayout.resolved(preferred: stored, idiom: .phone) == .cards)
    }
}

struct RowKeyTests {
    private static let columns = ["created_at", "name", "id", "code"].map { ColumnInfo(name: $0, typeName: "text") }

    @Test("The first primary key column in table order names the row")
    func primaryKeyNamesTheRow() {
        #expect(RowKey.columnIndex(columns: Self.columns, primaryKeys: ["id"]) == 2)
        #expect(RowKey.columnIndex(columns: Self.columns, primaryKeys: ["code", "id"]) == 2)
    }

    @Test("Without a primary key the first column names the row, and no columns name nothing")
    func firstColumnWithoutKey() {
        #expect(RowKey.columnIndex(columns: Self.columns, primaryKeys: []) == 0)
        #expect(RowKey.columnIndex(columns: [], primaryKeys: ["id"]) == nil)
    }
}
