//
//  ObjectListingIconStyleTests.swift
//  TableProTests
//

import AppKit
import Combine
import Foundation
import TableProPluginKit
import Testing

@testable import TablePro

extension GlobalStateSuites {
    @Suite(.appSettings { $0.appearance.objectIconStyle = .standard })
    @MainActor
    struct ObjectListingIconStyleTests {
        private let defaults: EphemeralDefaults

        init() throws {
            defaults = try EphemeralDefaults()
        }

        private func makeModel() -> TableListingViewModel {
            let model = TableListingViewModel(
                tabId: UUID(),
                scope: DatabaseScope(connectionId: UUID(), database: "shop", schema: nil),
                loader: TableListingLoader(databaseType: .mysql, slot: .database),
                refreshRequests: Empty().eraseToAnyPublisher(),
                columnVisibility: ObjectListingColumnVisibilityStore(defaults: defaults.defaults)
            )
            let tableRows = TableRows.from(
                queryRows: [[.text("shop"), .text("active_orders"), .text("VIEW")]],
                columns: ["Schema", "Name", "Type"],
                columnTypes: Array(repeating: .text(rawType: nil), count: 3)
            )
            let listing = TableListing(
                rows: tableRows, isIncomplete: false, statusMessage: nil,
                items: [.existing(0): .relation(name: "active_orders", schema: nil, type: .view)],
                columnKeys: ["schema", "name", "kind"]
            )
            model.list.show(listing, filterText: "")
            return model
        }

        private func nameGlyph(in table: NSTableView) throws -> NSImageView {
            let column = table.column(withIdentifier: NSUserInterfaceItemIdentifier("name"))
            let cell = try #require(table.view(atColumn: column, row: 0, makeIfNecessary: true) as? NSTableCellView)
            return try #require(cell.imageView)
        }

        @Test("The Name glyph on screen takes the colorful hue as soon as the setting changes, and gives it back")
        func visibleGlyphFollowsTheSetting() throws {
            let model = makeModel()
            let coordinator = ObjectListingTableCoordinator(list: model.list, model: model)
            let scrollView = coordinator.makeScrollView()
            defer { withExtendedLifetime(coordinator) {} }
            let table = try #require(scrollView.documentView as? NSTableView)
            let glyph = try nameGlyph(in: table)
            #expect(glyph.contentTintColor == .controlAccentColor)

            AppSettingsManager.shared.appearance.objectIconStyle = .colorful
            #expect(glyph.contentTintColor == .systemCyan)

            AppSettingsManager.shared.appearance.objectIconStyle = .standard
            #expect(glyph.contentTintColor == .controlAccentColor)
        }

        @Test("A list opened while the colorful style is on draws its glyphs in their hues")
        func newListStartsColorful() throws {
            AppSettingsManager.shared.appearance.objectIconStyle = .colorful
            let model = makeModel()
            let coordinator = ObjectListingTableCoordinator(list: model.list, model: model)
            let scrollView = coordinator.makeScrollView()
            defer { withExtendedLifetime(coordinator) {} }
            let table = try #require(scrollView.documentView as? NSTableView)

            #expect(try nameGlyph(in: table).contentTintColor == .systemCyan)
        }
    }
}
