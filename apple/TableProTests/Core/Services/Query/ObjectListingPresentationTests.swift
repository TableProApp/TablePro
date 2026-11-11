//
//  ObjectListingPresentationTests.swift
//  TableProTests
//

import Foundation
import TableProPluginKit
import Testing

@testable import TablePro

struct ObjectListingPresentationTests {
    private let utc = TimeZone(identifier: "UTC") ?? .current

    private var formatter: ObjectListingValueFormatter {
        ObjectListingValueFormatter(locale: Locale(identifier: "en_US"), timeZone: utc)
    }

    private func shown(_ text: String?, as format: ObjectListingValueFormat) -> String {
        formatter.display(.fromOptional(text), as: format)
    }

    private func key(_ text: String?, as format: ObjectListingValueFormat) -> ObjectListingSortKey {
        formatter.sortKey(.fromOptional(text), as: format)
    }

    // The app's own byte formatter, so the expectation follows the host's language the way the list does.
    private func bytes(_ count: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .binary
        formatter.allowsNonnumericFormatting = false
        return formatter.string(fromByteCount: count)
    }

    /// The MySQL listing's columns, in the order its statement selects them.
    private static let mysqlColumns = [
        "schema", "name", "kind", "charset", "collation", "estimated_rows", "total_size", "data_size", "index_size",
        "engine", "create_time", "update_time", "comment",
    ]

    private func listing(_ columns: [String], _ rows: [[String?]]) -> TableListing {
        let tableRows = TableRows.from(
            queryRows: rows.map { $0.map(PluginCellValue.fromOptional) },
            columns: columns.map(ObjectListingColumns.displayTitle(for:)),
            columnTypes: Array(repeating: .text(rawType: nil), count: columns.count)
        )
        let items = ObjectListingColumns(columns: columns)?.items(
            in: tableRows, containerSchema: nil, readsSchemaColumn: false
        ) ?? [:]
        return TableListing(rows: tableRows, isIncomplete: false, statusMessage: nil, items: items, columnKeys: columns)
    }

    private func mysqlRow(
        _ name: String,
        rows: String? = "10",
        data: String? = "16384",
        updated: String? = "2026-11-10 07:00:30",
        comment: String? = "Kept"
    ) -> [String?] {
        ["shop", name, "BASE TABLE", "utf8mb4", "utf8mb4_unicode_ci", rows, "32768", data, "16384",
         "InnoDB", "2026-08-12 08:05:33", updated, comment]
    }

    // MARK: - Counts

    @Test("A count reads with grouping separators, and text that is not a count shows as it came")
    func countsGroupTheirDigits() {
        #expect(shown("6215717", as: .count) == "6,215,717")
        #expect(shown("570", as: .count) == "570")
        #expect(shown("12.0", as: .count) == "12")
        #expect(shown("n/a", as: .count) == "n/a")
        #expect(shown("", as: .count) == "")
        #expect(shown(nil, as: .count) == "")
    }

    @Test("Counts sort as numbers, with an empty cell before every count")
    func countsSortAsNumbers() {
        #expect(key("9", as: .count) < key("10", as: .count))
        #expect(key(nil, as: .count) < key("0", as: .count))
        #expect(key("", as: .count) == .missing)
    }

    // MARK: - Sizes

    @Test("A size in bytes reads as a byte count in binary units")
    func bytesReadAsByteCounts() {
        #expect(shown("163840", as: .bytes) == bytes(163_840))
        #expect(shown("2050000000", as: .bytes) == bytes(2_050_000_000))
        #expect(shown("0", as: .bytes) == bytes(0))
        #expect(shown("163840", as: .bytes).contains("160"))
    }

    @Test("A size a plugin formatted itself shows as it came", arguments: ["16 kB", "0.05 MB", "1,2 GB", "-"])
    func formattedSizesPassThrough(text: String) {
        #expect(shown(text, as: .bytes) == text)
    }

    @Test("Sizes sort by bytes, including the ones a plugin formatted in 1,024s")
    func sizesSortByBytes() {
        #expect(key("16384", as: .bytes) == .number(16_384))
        #expect(key("16 kB", as: .bytes) == .number(16_384))
        #expect(key("0.05 MB", as: .bytes) == .number(0.05 * 1_048_576))
        #expect(key("16 kB", as: .bytes) < key("1 MB", as: .bytes))
        #expect(key("a lot", as: .bytes) == .text("a lot"))
    }

    @Test("Only plain decimal digits count as a number", arguments: [
        ("42", 42.0), ("-5", -5.0), ("3.25", 3.25), (" 7 ", 7.0),
    ])
    func plainDigitsAreNumbers(text: String, value: Double) {
        #expect(ObjectListingValueFormatter.number(in: text) == value)
    }

    @Test("Words Swift would read as a number are not one here", arguments: ["nan", "inf", "0x10", "1e5", "1.2.3", "", "-"])
    func otherSpellingsAreNotNumbers(text: String) {
        #expect(ObjectListingValueFormatter.number(in: text) == nil)
    }

    // MARK: - Dates

    @Test("A catalog timestamp shows in one fixed shape", arguments: [
        ("2026-08-12 08:05:33", "2026-08-12 08:05:33"),
        ("2026-08-12 08:05:33.123456", "2026-08-12 08:05:33"),
        ("2026-08-12T08:05:33", "2026-08-12 08:05:33"),
        ("2026-08-12 08:05", "2026-08-12 08:05:00"),
        ("2026-08-12T08:05:33Z", "2026-08-12 08:05:33"),
    ])
    func timestampsShowInOneShape(text: String, expected: String) {
        #expect(shown(text, as: .date) == expected)
    }

    // A wall clock without a zone is the server's, which the client cannot place, so it stays as written.
    @Test("A timestamp with an offset shows in the reader's zone, and one without stays the server's wall clock")
    func offsetsMoveToTheReadersZone() throws {
        let saigon = try #require(TimeZone(identifier: "Asia/Ho_Chi_Minh"))
        let local = ObjectListingValueFormatter(locale: Locale(identifier: "en_US"), timeZone: saigon)

        #expect(local.display(.text("2026-08-12 08:05:33+02:00"), as: .date) == "2026-08-12 13:05:33")
        #expect(local.display(.text("2026-08-12 23:30:00Z"), as: .date) == "2026-08-13 06:30:00")
        #expect(local.display(.text("2026-08-12 08:05:33"), as: .date) == "2026-08-12 08:05:33")
    }

    @Test("Text that is not a timestamp shows as it came", arguments: ["yesterday", "2026-13-01 00:00:00", "2026-08-12", ""])
    func otherDatesPassThrough(text: String) {
        #expect(shown(text, as: .date) == text)
    }

    @Test("Timestamps sort by the instant they name")
    func timestampsSortByInstant() {
        #expect(key("2026-08-12 08:05:33", as: .date) < key("2026-08-12 08:05:34", as: .date))
        #expect(key("2026-08-12 08:00:00+02", as: .date) < key("2026-08-12 07:00:00Z", as: .date))
        #expect(key(nil, as: .date) == .missing)
    }

    @Test("Text keeps its spelling and sorts the way Finder sorts names")
    func textSortsLikeFinder() {
        #expect(shown("InnoDB", as: .text) == "InnoDB")
        #expect(key("table2", as: .text) < key("table10", as: .text))
        #expect(key("Alpha", as: .text) < key("beta", as: .text))
    }

    // MARK: - Columns

    @Test("A Tables listing shows Name, Rows, Data Length, Engine, the dates, Collation and Comment, in that order")
    func tablesColumnsInTheirOrder() {
        let columns = ObjectListingColumnLayout.columns(
            of: listing(Self.mysqlColumns, [mysqlRow("orders", comment: "Paid orders")]),
            containerName: "shop"
        )

        #expect(columns.filter { $0.isShownByDefault }.map { $0.title } == [
            String(localized: "Name"), String(localized: "Rows"), String(localized: "Data Length"),
            String(localized: "Engine"), String(localized: "Created Date"), String(localized: "Modified Date"),
            String(localized: "Collation"), String(localized: "Comment"),
        ])
        #expect(columns.map { $0.id } == [
            "name", "estimated_rows", "data_size", "engine", "create_time", "update_time", "collation", "comment",
            "schema", "kind", "charset", "total_size", "index_size",
        ])
        #expect(columns.first { $0.id == "estimated_rows" }?.format == .count)
        #expect(columns.first { $0.id == "data_size" }?.format == .bytes)
        #expect(columns.first { $0.id == "create_time" }?.format == .date)
    }

    // Modified Date is empty for this InnoDB table, but a later row could carry one: only a column every row leaves empty hides.
    @Test("A column every row leaves empty starts hidden; one some rows fill stays")
    func emptyColumnsStartHidden() {
        let columns = ObjectListingColumnLayout.columns(
            of: listing(Self.mysqlColumns, [mysqlRow("orders", comment: ""), mysqlRow("audit", comment: "Kept 90 days")]),
            containerName: "shop"
        )
        let modified = ObjectListingColumnLayout.columns(
            of: listing(Self.mysqlColumns, [mysqlRow("orders", updated: nil, comment: "")]),
            containerName: "shop"
        )

        #expect(columns.first { $0.id == "comment" }?.isShownByDefault == true)
        #expect(modified.first { $0.id == "update_time" }?.isShownByDefault == false)
        #expect(modified.first { $0.id == "comment" }?.isShownByDefault == false)
    }

    @Test("Schema starts hidden while it names only the listed container, and shows when a row names another")
    func schemaHidesWhenItRepeatsTheContainer() {
        let same = listing(["schema", "name"], [["shop", "orders"], ["", "customers"]])
        let mixed = listing(["schema", "name"], [["shop", "orders"], ["archive", "orders"]])

        #expect(ObjectListingColumnLayout.columns(of: same, containerName: "shop").first { $0.id == "schema" }?.isShownByDefault == false)
        #expect(ObjectListingColumnLayout.columns(of: mixed, containerName: "shop").first { $0.id == "schema" }?.isShownByDefault == true)
    }

    @Test("Total Size shows in Data Length's place where a listing has none, as ClickHouse's has none")
    func totalSizeStandsInForDataLength() {
        let clickhouse = listing(["schema", "name", "kind", "estimated_rows", "total_size", "comment"], [
            ["default", "events", "MergeTree", "100", "1.20 MiB", "Raw events"],
        ])

        let columns = ObjectListingColumnLayout.columns(of: clickhouse, containerName: "default")

        #expect(columns.filter { $0.isShownByDefault }.map { $0.id } == ["name", "estimated_rows", "total_size", "comment"])
    }

    @Test("A column only this plugin lists keeps its spelling and shows after Comment, in the plugin's order")
    func unknownColumnsFollowComment() {
        let redshift = listing(["schema", "name", "kind", "estimated_rows", "size_mb", "pct_used"], [
            ["public", "events", "TABLE", "100", "12", "0.5"],
        ])

        let columns = ObjectListingColumnLayout.columns(of: redshift, containerName: "public")

        #expect(columns.map { $0.id } == ["name", "estimated_rows", "size_mb", "pct_used", "schema", "kind"])
        #expect(columns.first { $0.id == "size_mb" }?.title == "size_mb")
        #expect(columns.first { $0.id == "size_mb" }?.isShownByDefault == true)
    }

    @Test("MySQL's SHOW TABLE STATUS columns read as the same fields")
    func tableStatusAliasesAreKnown() {
        #expect(ObjectListingField(alias: "Rows") == .rows)
        #expect(ObjectListingField(alias: "Data_length") == .dataSize)
        #expect(ObjectListingField(alias: "Index_length") == .indexSize)
        #expect(ObjectListingField(alias: "Avg_row_length") == nil)
    }

    @Test("Another kind's built columns keep their order, and its Schema hides while it repeats the container")
    func builtKindsKeepTheirColumns() {
        let routines = [
            RoutineInfo(name: "touch", kind: .function, schema: "sales", argumentSignature: "(integer)", returnType: "integer", language: "plpgsql"),
        ]
        let built = ObjectListingRows.listing(
            kind: .function,
            from: .routines(routines),
            scope: DatabaseScope(connectionId: UUID(), database: "shop", schema: "sales")
        )

        let columns = ObjectListingColumnLayout.columns(of: built, containerName: "sales")

        #expect(columns.map { $0.id } == ["name", "arguments", "returns", "language", "schema"])
        #expect(columns.filter { $0.isShownByDefault }.map { $0.id } == ["name", "arguments", "returns", "language"])
    }

    @Test("Two columns sharing one alias keep apart, so each can be shown or hidden")
    func duplicateAliasesGetTheirOwnIds() {
        let doubled = listing(["name", "note", "note"], [["orders", "a", "b"]])

        let ids = ObjectListingColumnLayout.columns(of: doubled, containerName: nil).map(\.id)

        #expect(Set(ids).count == 3)
    }

    // MARK: - Rows

    @Test("Each row carries its object, the sidebar's glyph and its formatted values")
    func rowsCarryTheirObject() throws {
        let source = listing(Self.mysqlColumns, [mysqlRow("orders", rows: "6215717", data: "163840", updated: nil)])
        let columns = ObjectListingColumnLayout.columns(of: source, containerName: "shop")

        let row = try #require(ObjectListingRowBuilder.rows(of: source, columns: columns, formatter: formatter).first)

        #expect(row.item == .relation(name: "orders", schema: nil, type: .table))
        #expect(row.item.iconKind == .relation(.table))
        #expect(ObjectIconProvider.icon(for: row.item.iconKind, style: .standard).symbolName == TableRowLogic.iconName(for: .table))
        #expect(row.texts[5] == "6,215,717")
        #expect(row.texts[7] == bytes(163_840))
        #expect(row.texts[10] == "2026-08-12 08:05:33")
        #expect(row.texts[11] == "")
    }

    @Test("A source object shows its own kind's glyph")
    func sourcedRowsShowTheirKind() throws {
        let built = ObjectListingRows.listing(
            kind: .function,
            from: .routines([RoutineInfo(name: "touch", kind: .function, schema: "sales")]),
            scope: DatabaseScope(connectionId: UUID(), database: "shop", schema: "sales")
        )
        let columns = ObjectListingColumnLayout.columns(of: built, containerName: "sales")

        let row = try #require(ObjectListingRowBuilder.rows(of: built, columns: columns, formatter: formatter).first)

        #expect(row.item.iconKind == .routine(.function))
        #expect(ObjectIconProvider.icon(for: row.item.iconKind, style: .standard).symbolName == SidebarObjectKind.function.iconName)
    }

    @Test("Rows sort by a column's values as numbers, and equal values keep the listing's order")
    func rowsSortByTheirValues() {
        let source = listing(Self.mysqlColumns, [
            mysqlRow("small", data: "16384"), mysqlRow("large", data: "2050000000"),
            mysqlRow("medium", data: "163840"), mysqlRow("twin", data: "16384"),
        ])
        let columns = ObjectListingColumnLayout.columns(of: source, containerName: "shop")
        let rows = ObjectListingRowBuilder.rows(of: source, columns: columns, formatter: formatter)

        let descending = ObjectListingRowBuilder.sorted(rows, by: ObjectListingSort(columnID: "data_size", ascending: false), columns: columns)
        let ascending = ObjectListingRowBuilder.sorted(rows, by: ObjectListingSort(columnID: "data_size", ascending: true), columns: columns)
        let unsorted = ObjectListingRowBuilder.sorted(rows, by: nil, columns: columns)

        #expect(descending.map { $0.item.name } == ["large", "medium", "small", "twin"])
        #expect(ascending.map { $0.item.name } == ["small", "twin", "medium", "large"])
        #expect(unsorted.map { $0.item.name } == ["small", "large", "medium", "twin"])
    }
}
