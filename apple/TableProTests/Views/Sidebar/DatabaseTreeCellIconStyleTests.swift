//
//  DatabaseTreeCellIconStyleTests.swift
//  TableProTests
//

import AppKit
import Foundation
@testable import TablePro
import Testing

extension GlobalStateSuites {
    @Suite(.appSettings { $0.appearance.objectIconStyle = .standard })
    @MainActor
    struct DatabaseTreeCellIconStyleTests {
        private final class FieldDelegate: NSObject, NSTextFieldDelegate {}

        private func viewCell() -> DatabaseTreeCellView {
            let view = TableInfo(name: "active_orders", type: .view, rowCount: nil)
            let node = DatabaseTreeNode(
                id: "view",
                kind: .table(DatabaseTreeTableRef(database: "shop", schema: nil, table: view))
            )
            let cell = DatabaseTreeCellView()
            cell.configure(
                node: node,
                isFavorite: false,
                context: DatabaseTreeRowContext(
                    databaseType: .mysql,
                    activeDatabase: "shop",
                    activeSchema: nil,
                    systemSchemas: [],
                    pendingTruncates: [],
                    pendingDeletes: []
                ),
                actions: DatabaseTreeRowActions(toggleFavorite: { _ in }, toggleFavoriteDatabase: { _ in })
            )
            return cell
        }

        @Test("A configured cell takes the new style when the setting changes, without being configured again")
        func cellFollowsTheSetting() {
            let cell = viewCell()
            #expect(cell.renameIcon == ObjectIcon(symbolName: "eye"))
            #expect(cell.editorSymbolTint == nil)

            AppSettingsManager.shared.appearance.objectIconStyle = .colorful

            #expect(cell.renameIcon == ObjectIcon(symbolName: "eyeglasses", tint: .cyan))
            #expect(cell.editorSymbolName == "eyeglasses")
            #expect(cell.editorSymbolTint == .systemCyan)
        }

        @Test("The rename glyph wears the hue, and turns to AppKit's selected color on the emphasized selection")
        func renameGlyphKeepsTheSelectionTreatment() throws {
            AppSettingsManager.shared.appearance.objectIconStyle = .colorful
            let cell = viewCell()
            let delegate = FieldDelegate()

            cell.beginRename(text: "active_orders", delegate: delegate)
            let glyph = try #require(cell.imageView)
            #expect(glyph.contentTintColor == .systemCyan)

            cell.backgroundStyle = .emphasized
            #expect(glyph.contentTintColor == nil)

            cell.backgroundStyle = .normal
            #expect(glyph.contentTintColor == .systemCyan)
            _ = cell.endRename()
        }
    }
}
