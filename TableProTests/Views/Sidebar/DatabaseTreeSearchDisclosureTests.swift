//
//  DatabaseTreeSearchDisclosureTests.swift
//  TableProTests
//

import Foundation
@testable import TablePro
import TableProPluginKit
import Testing

struct DatabaseTreeSearchDisclosureTests {
    private let rows = [TableInfo(name: "timesheet", type: .table, rowCount: nil, schema: "attendance")]

    private func source(
        searching: Bool,
        tables: MetadataLoadPhase,
        isTablesCurrent: Bool = false,
        listingRows: [TableInfo]?
    ) -> DatabaseTreeFilter.SchemaContentSource {
        DatabaseTreeFilter.schemaContentSource(
            searching: searching,
            tables: tables,
            isTablesCurrent: isTablesCurrent,
            listingRows: listingRows
        )
    }

    @Test("A schema the search opens reads nothing, read before or not")
    func searchDisclosureReadsNothing() {
        #expect(!DatabaseTreeFilter.readsOnDisclosure(origin: .search))
    }

    @Test("A schema opened by hand or restored reads")
    func userAndRestoreRead() {
        #expect(DatabaseTreeFilter.readsOnDisclosure(origin: .user))
        #expect(DatabaseTreeFilter.readsOnDisclosure(origin: .restore))
    }

    @Test("A schema's own current tables beat the listing")
    func currentLoadedBeatsListing() {
        #expect(source(searching: true, tables: .loaded, isTablesCurrent: true, listingRows: rows) == .loaded)
    }

    @Test("Tables a change overtook yield to the listing while searching")
    func staleLoadedYieldsToListing() {
        #expect(source(searching: true, tables: .loaded, isTablesCurrent: false, listingRows: rows) == .listing(rows))
    }

    @Test("The listing answers an unread schema only while searching")
    func listingOnlyWhileSearching() {
        #expect(source(searching: true, tables: .idle, listingRows: rows) == .listing(rows))
        #expect(source(searching: false, tables: .idle, listingRows: rows) == .pending)
        #expect(source(searching: false, tables: .loaded, listingRows: rows) == .loaded)
    }

    @Test("The listing keeps answering while a read started by hand runs")
    func listingKeptDuringAHandStartedRead() {
        #expect(source(searching: true, tables: .loading, listingRows: rows) == .listing(rows))
    }

    @Test("A failed read passes through where the listing cannot answer")
    func failurePassesThrough() {
        #expect(source(searching: true, tables: .failed("denied"), listingRows: nil) == .failed("denied"))
        #expect(source(searching: false, tables: .failed("denied"), listingRows: rows) == .failed("denied"))
    }

    @Test("An unread schema outside a search is pending")
    func pendingOutsideSearch() {
        #expect(source(searching: false, tables: .loading, listingRows: nil) == .pending)
        #expect(source(searching: true, tables: .idle, listingRows: nil) == .pending)
    }
}
