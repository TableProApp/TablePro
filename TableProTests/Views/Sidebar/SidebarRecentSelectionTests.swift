//
//  SidebarRecentSelectionTests.swift
//  TableProTests
//

import Foundation
import TableProPluginKit
import Testing

@testable import TablePro

/// The sidebar's object list selects by `TableInfo`, and a Recent entry keeps its own copy of the
/// table taken when it was opened. These are the properties that make tagging a Recent row with
/// that copy correct: the copy still identifies the same table, so the row highlights and the
/// selection means what the rest of the app expects it to mean.
@Suite("Sidebar recent selection identity")
struct SidebarRecentSelectionTests {
    private func table(
        _ name: String,
        schema: String? = "public",
        type: TableInfo.TableType = .table,
        rowCount: Int? = nil,
        comment: String? = nil
    ) -> TableInfo {
        TableInfo(name: name, type: type, rowCount: rowCount, schema: schema, comment: comment)
    }

    /// A stored Recent copy carries the row count and comment from when it was opened. Identity
    /// ignores both, so it still matches the live row and the two rows agree.
    @Test("Metadata that drifts does not change identity")
    func metadataDoesNotAffectIdentity() {
        let stored = table("users", rowCount: nil, comment: nil)
        let live = table("users", rowCount: 42, comment: "people")
        #expect(stored == live)
        #expect(stored.hashValue == live.hashValue)
        #expect(Set([stored, live]).count == 1)
    }

    @Test("Name, schema and type are all part of identity")
    func identityCoversTheQualifiedName() {
        #expect(table("users", schema: "app") != table("users", schema: "public"))
        #expect(table("users") != table("orders"))
        #expect(table("users", type: .table) != table("users", type: .view))
    }

    /// A Recent row and the object-list row for the same table therefore carry the same selection
    /// tag, so selecting either shows the table as selected in both places it appears.
    @Test("A recent row and its object-list row share one selection value")
    func recentAndListRowShareSelection() {
        let selection: Set<TableInfo> = [table("users", rowCount: nil)]
        #expect(selection.contains(table("users", rowCount: 42)))
    }

    /// `RecentTableRow` has to stay distinct from the object-list row inside `ForEach`, or SwiftUI
    /// would treat the two as one view even though they select as one table.
    @Test("A recent row keeps a view identity of its own")
    func recentRowHasDistinctViewIdentity() {
        let info = table("users")
        #expect(RecentTableRow(table: info).id != info.id)
        #expect(RecentTableRow(table: info).id.contains(info.id))
    }
}
