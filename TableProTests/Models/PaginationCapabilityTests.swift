//
//  PaginationCapabilityTests.swift
//  TableProTests
//

import AppKit
import Foundation
import TableProPluginKit
import Testing

@testable import TablePro

@MainActor
struct PaginationCapabilityTests {
    private let leadingRows = PaginationCapability.leadingRowsOnly(maximumRows: 10_000)

    @Test("An offset engine seeks and caps nothing")
    func offsetEngine() {
        #expect(PaginationCapability.offset.allowsSeeking)
        #expect(PaginationCapability.offset.maximumRows == nil)
        #expect(PaginationCapability.offset.clampedRowCount(50_000) == 50_000)
    }

    @Test("A leading-rows engine never seeks and clamps to its ceiling")
    func leadingRowsEngine() {
        #expect(!leadingRows.allowsSeeking)
        #expect(leadingRows.maximumRows == 10_000)
        #expect(leadingRows.clampedRowCount(50_000) == 10_000)
        #expect(leadingRows.clampedRowCount(500) == 500)
    }

    @Test("Cloudflare R2 SQL reads its capability from the catalog, and other engines keep offset paging")
    func catalog() {
        #expect(PaginationCapability.of(.cloudflareR2SQL) == .leadingRowsOnly(maximumRows: 10_000))
        #expect(PaginationCapability.of(.postgresql) == .offset)
    }

    @Test("Cassandra and ScyllaDB cannot skip rows and cap nothing")
    func cassandraDeclaresNoSeekAndNoCeiling() {
        for type in [DatabaseType.cassandra, .scylladb] {
            let declared = PaginationCapability.of(type)
            #expect(declared == .leadingRowsOnly(maximumRows: nil))
            #expect(!declared.allowsSeeking)
            #expect(declared.maximumRows == nil)
            #expect(declared.clampedRowCount(500_000) == 500_000)
        }
    }

    @Test("An engine with no ceiling pages through a plugin that builds its own browse, and reads leading rows otherwise")
    func noCeilingResolvesByPlugin() {
        let noCeiling = PaginationCapability.leadingRowsOnly(maximumRows: nil)

        #expect(noCeiling.resolved(pluginBuildsBrowse: true) == .offset)
        #expect(noCeiling.resolved(pluginBuildsBrowse: false) == noCeiling)
        #expect(leadingRows.resolved(pluginBuildsBrowse: true) == leadingRows)
        #expect(PaginationCapability.offset.resolved(pluginBuildsBrowse: false) == .offset)
    }

    @Test("Without its own browse, a Cassandra table query reads the leading rows with no OFFSET and no ceiling")
    func cassandraHostQueryReadsLeadingRows() {
        let builder = TableQueryBuilder(databaseType: .cassandra, pagination: .leadingRowsOnly(maximumRows: nil))
        let query = builder.buildBaseQuery(tableName: "users", schemaName: "shop", limit: 500_000, offset: 3_000)

        #expect(query == #"SELECT * FROM "shop"."users" LIMIT 500000"#)
    }

    @Test("Where no plugin builds the browse, the app resolves Cassandra to its leading rows")
    func pluginManagerResolvesWithoutAPlugin() {
        #expect(PluginManager.shared.paginationCapability(for: .cassandra) == .leadingRowsOnly(maximumRows: nil))
        #expect(PluginManager.shared.paginationCapability(for: .postgresql) == .offset)
    }

    @Test("A leading-rows table query states a clamped LIMIT and never an OFFSET")
    func builderNeverOffsets() {
        let builder = TableQueryBuilder(databaseType: .cloudflareR2SQL, pagination: leadingRows)
        let query = builder.buildBaseQuery(tableName: "events", schemaName: "logs", limit: 50_000, offset: 0)

        #expect(query == #"SELECT * FROM "logs"."events" LIMIT 10000"#)
        #expect(!query.contains("OFFSET"))
    }

    @Test("An offset table query keeps LIMIT and OFFSET")
    func builderOffsets() {
        let builder = TableQueryBuilder(databaseType: .postgresql, pagination: .offset)
        let query = builder.buildBaseQuery(tableName: "events", limit: 100, offset: 200)

        #expect(query.hasSuffix("LIMIT 100 OFFSET 200"))
    }

    private func snapshot(rowCount: Int, pageSize: Int, capability: PaginationCapability) -> StatusBarSnapshot {
        StatusBarSnapshot(
            tabId: UUID(),
            tabType: .table,
            hasRows: rowCount > 0,
            hasColumns: true,
            rowCount: rowCount,
            hasTableName: true,
            pagination: PaginationState(pageSize: pageSize),
            statusMessage: nil,
            paginationCapability: capability
        )
    }

    @Test("A leading-rows table keeps the rows-per-page menu and drops page navigation")
    func controls() {
        let capped = ResultStatusModel(
            snapshot: snapshot(rowCount: 500, pageSize: 500, capability: leadingRows),
            viewMode: .data,
            selectedRowCount: 0
        )
        let paged = ResultStatusModel(
            snapshot: snapshot(rowCount: 500, pageSize: 500, capability: .offset),
            viewMode: .data,
            selectedRowCount: 0
        )

        #expect(capped.controls.showsPagination && !capped.controls.showsPageNavigation)
        #expect(paged.controls.showsPagination && paged.controls.showsPageNavigation)
    }

    @Test("The readout says what loaded: a range of unknown total at the limit, a count below it")
    func readout() {
        let atLimit = ResultStatusModel(
            snapshot: snapshot(rowCount: 500, pageSize: 500, capability: leadingRows),
            viewMode: .data,
            selectedRowCount: 0
        )
        let belowLimit = ResultStatusModel(
            snapshot: snapshot(rowCount: 37, pageSize: 500, capability: leadingRows),
            viewMode: .data,
            selectedRowCount: 0
        )

        #expect(atLimit.readout == .rangeOfUnknownTotal(start: 1, end: 500))
        #expect(belowLimit.readout == .rowCount(37))
    }

    @Test("Page-size presets stop at the engine's ceiling")
    func presets() {
        #expect(PaginationControlsView.pageSizePresets(upTo: nil) == [5, 10, 20, 100, 500, 1_000])
        #expect(PaginationControlsView.pageSizePresets(upTo: 100) == [5, 10, 20, 100])
    }

    @Test("Page commands are dimmed where the engine cannot skip rows")
    func pageCommands() {
        let selectors = [
            #selector(MainSplitViewController.goToFirstPage(_:)),
            #selector(MainSplitViewController.goToPreviousPage(_:)),
            #selector(MainSplitViewController.goToNextPage(_:)),
            #selector(MainSplitViewController.goToLastPage(_:))
        ]
        var context = MenuValidationContext()
        context.isConnected = true
        for selector in selectors {
            #expect(!MainSplitViewController.isEnabled(selector, context: context))
        }

        context.canNavigatePages = true
        for selector in selectors {
            #expect(MainSplitViewController.isEnabled(selector, context: context))
        }
    }
}
