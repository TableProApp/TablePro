import Foundation
@testable import TableProMobile
import TableProModels
import Testing

struct ForeignKeyReferenceTests {
    private static func column(_ name: String, _ index: Int) -> ColumnInfo {
        ColumnInfo(name: name, typeName: "TEXT", ordinalPosition: index)
    }

    private static let orderColumns = [column("id", 0), column("tenant_id", 1), column("user_id", 2), column("note", 3)]

    private static let userKey = ForeignKeyInfo(
        name: "orders_user_fk", column: "user_id", referencedTable: "users", referencedColumn: "id"
    )

    private static let tenantUserKey = [
        ForeignKeyInfo(name: "orders_tenant_user_fk", column: "tenant_id", referencedTable: "tenant_users", referencedColumn: "tenant_id"),
        ForeignKeyInfo(name: "orders_tenant_user_fk", column: "user_id", referencedTable: "tenant_users", referencedColumn: "id")
    ]

    private static func cells(_ values: Cell...) -> [Cell] { values }

    @Test("A single-column key reads the cell and keeps the source schema when the key names none")
    func singleColumnKey() throws {
        let reference = try #require(ForeignKeyReference.make(
            forColumn: "user_id",
            foreignKeys: [Self.userKey],
            columns: Self.orderColumns,
            cells: Self.cells(.text("1"), .text("2"), .text("5"), .null),
            sourceSchema: "public"
        ))
        #expect(reference.table == "users")
        #expect(reference.schema == "public")
        #expect(reference.parts == [ForeignKeyReference.Part(column: "id", value: "5")])
    }

    @Test("The key's own schema wins over the source schema")
    func referencedSchemaWins() throws {
        let key = ForeignKeyInfo(
            name: "orders_user_fk", column: "user_id", referencedTable: "users", referencedColumn: "id",
            referencedSchema: "crm"
        )
        let reference = try #require(ForeignKeyReference.make(
            forColumn: "user_id", foreignKeys: [key], columns: Self.orderColumns,
            cells: Self.cells(.text("1"), .text("2"), .text("5"), .null), sourceSchema: "public"
        ))
        #expect(reference.schema == "crm")
    }

    @Test("A composite key carries every pair in key order, whichever of its columns was tapped")
    func compositeKeyCarriesEveryPair() throws {
        let cells = Self.cells(.text("1"), .text("2"), .text("5"), .null)
        for tapped in ["tenant_id", "user_id"] {
            let reference = try #require(ForeignKeyReference.make(
                forColumn: tapped, foreignKeys: Self.tenantUserKey, columns: Self.orderColumns,
                cells: cells, sourceSchema: nil
            ))
            #expect(reference.table == "tenant_users")
            #expect(reference.parts == [
                ForeignKeyReference.Part(column: "tenant_id", value: "2"),
                ForeignKeyReference.Part(column: "id", value: "5")
            ])
        }
    }

    @Test("A NULL, binary or truncated key cell gives no reference, so no placeholder text is used as a key")
    func nonTextCellsGiveNoReference() {
        let placeholders: [Cell] = [
            .null,
            .binary(byteCount: 16, ref: nil),
            .truncatedText(prefix: "abc", totalBytes: 9_000, ref: nil)
        ]
        for placeholder in placeholders {
            #expect(ForeignKeyReference.make(
                forColumn: "user_id", foreignKeys: [Self.userKey], columns: Self.orderColumns,
                cells: Self.cells(.text("1"), .text("2"), placeholder, .null), sourceSchema: nil
            ) == nil)
        }
    }

    @Test("One NULL column in a composite key gives no reference")
    func compositeKeyWithNullPart() {
        #expect(ForeignKeyReference.make(
            forColumn: "user_id", foreignKeys: Self.tenantUserKey, columns: Self.orderColumns,
            cells: Self.cells(.text("1"), .null, .text("5"), .null), sourceSchema: nil
        ) == nil)
    }

    @Test("A key column missing from the result gives no reference")
    func missingKeyColumn() {
        let columns = [Self.column("id", 0), Self.column("user_id", 1)]
        #expect(ForeignKeyReference.make(
            forColumn: "user_id", foreignKeys: Self.tenantUserKey, columns: columns,
            cells: Self.cells(.text("1"), .text("5")), sourceSchema: nil
        ) == nil)
    }

    @Test("A column in no key gives no reference")
    func columnWithoutKey() {
        #expect(ForeignKeyReference.make(
            forColumn: "note", foreignKeys: [Self.userKey], columns: Self.orderColumns,
            cells: Self.cells(.text("1"), .text("2"), .text("5"), .text("x")), sourceSchema: nil
        ) == nil)
    }

    @Test("A key column spelled in another case reads its single match")
    func keyColumnCaseFolds() throws {
        let key = ForeignKeyInfo(name: "fk_orders_0", column: "USER_ID", referencedTable: "users", referencedColumn: "id")
        let reference = try #require(ForeignKeyReference.make(
            forColumn: "user_id", foreignKeys: [key], columns: Self.orderColumns,
            cells: Self.cells(.text("1"), .text("2"), .text("5"), .null), sourceSchema: nil
        ))
        #expect(reference.parts == [ForeignKeyReference.Part(column: "id", value: "5")])
    }

    @Test("Every key gives one entry, a composite one included, and a key with a NULL part is left out")
    func allGivesOneEntryPerKey() {
        let noteKey = ForeignKeyInfo(name: "orders_note_fk", column: "note", referencedTable: "notes", referencedColumn: "id")
        let entries = ForeignKeyReference.all(
            foreignKeys: Self.tenantUserKey + [Self.userKey, noteKey],
            columns: Self.orderColumns,
            cells: Self.cells(.text("1"), .text("2"), .text("5"), .null),
            sourceSchema: nil
        )
        #expect(entries.map { $0.name } == ["orders_tenant_user_fk", "orders_user_fk"])
        #expect(entries.map { $0.column } == ["tenant_id, user_id", "user_id"])
        #expect(entries.map { $0.reference.table } == ["tenant_users", "users"])
        #expect(entries.first?.reference.parts.count == 2)
    }

    @Test("The schema shows only when it differs from the current one")
    func displaySchema() {
        func reference(_ schema: String?) -> ForeignKeyReference {
            ForeignKeyReference(table: "users", schema: schema, parts: [ForeignKeyReference.Part(column: "id", value: "5")])
        }
        #expect(reference("public").displaySchema(current: "public") == nil)
        #expect(reference(nil).displaySchema(current: "public") == nil)
        #expect(reference(nil).displaySchema(current: nil) == nil)
        #expect(reference("crm").displaySchema(current: "public") == "crm")
        #expect(reference("billing").displaySchema(current: nil) == "billing")
    }

    @Test("The catalog's own table is used in the current schema, by exact name or its single case-insensitive match")
    func catalogTableInCurrentSchema() {
        let catalog = [
            TableInfo(name: "customers", type: .table, rowCount: 3),
            TableInfo(name: "Regions", type: .foreignTable)
        ]
        let exact = ForeignKeyReference(table: "customers", schema: "public", parts: [])
        #expect(exact.catalogTable(in: catalog, currentSchema: "public") == catalog[0])

        let folded = ForeignKeyReference(table: "regions", schema: nil, parts: [])
        #expect(folded.catalogTable(in: catalog, currentSchema: nil) == catalog[1])
    }

    @Test("Another schema, an unknown name or two case-insensitive matches build a plain table")
    func catalogTableFallsBack() {
        let catalog = [TableInfo(name: "users", type: .view), TableInfo(name: "Zips", type: .view), TableInfo(name: "ZIPS", type: .view)]
        let plain = { (name: String) in TableInfo(name: name, type: .table) }

        let otherSchema = ForeignKeyReference(table: "users", schema: "crm", parts: [])
        #expect(otherSchema.catalogTable(in: catalog, currentSchema: "public") == plain("users"))

        let unknown = ForeignKeyReference(table: "invoices", schema: nil, parts: [])
        #expect(unknown.catalogTable(in: catalog, currentSchema: nil) == plain("invoices"))

        let ambiguous = ForeignKeyReference(table: "zips", schema: nil, parts: [])
        #expect(ambiguous.catalogTable(in: catalog, currentSchema: nil) == plain("zips"))
    }

    @Test("Filters are one case-sensitive equality per pair, all enabled")
    func filtersPerPair() throws {
        let reference = ForeignKeyReference(table: "tenant_users", schema: nil, parts: [
            ForeignKeyReference.Part(column: "tenant_id", value: "2"),
            ForeignKeyReference.Part(column: "id", value: "05")
        ])
        let filters = try #require(reference.filters())
        #expect(filters.map { $0.columnName } == ["tenant_id", "id"])
        #expect(filters.map { $0.value } == ["2", "05"])
        #expect(filters.allSatisfy { $0.filterOperator == .equal && $0.isEnabled && $0.isCaseSensitive && $0.isValid })
    }

    @Test("A blank or whitespace value gives no filters, since the browser would drop them and show every row")
    func blankValueGivesNoFilters() {
        for blank in ["", "  "] {
            let reference = ForeignKeyReference(table: "tenant_users", schema: nil, parts: [
                ForeignKeyReference.Part(column: "tenant_id", value: "2"),
                ForeignKeyReference.Part(column: "id", value: blank)
            ])
            #expect(reference.filters() == nil)
        }
    }

    @Test("The Structure screen shows a composite key as one row with every column pair")
    func structureRowsGroupCompositeKeys() {
        let rows = ForeignKeyReference.keys(in: [Self.userKey] + Self.tenantUserKey).map(StructureView.ForeignKeyRow.init)

        #expect(rows.map(\.reference) == [
            "user_id \u{2192} users.id",
            "tenant_id, user_id \u{2192} tenant_users (tenant_id, id)"
        ])
        #expect(Set(rows.map(\.id)).count == 2)
    }

    @Test("Keys sharing a name but pointing at different tables stay separate rows")
    func structureRowsKeepSameNamedKeysApart() {
        let rows = ForeignKeyReference.keys(in: [
            ForeignKeyInfo(name: "fk", column: "a", referencedTable: "p", referencedColumn: "id"),
            ForeignKeyInfo(name: "fk", column: "b", referencedTable: "q", referencedColumn: "id")
        ]).map(StructureView.ForeignKeyRow.init)

        #expect(rows.count == 2)
        #expect(Set(rows.map(\.id)).count == 2)
    }
}
