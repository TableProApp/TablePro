//
//  FavoriteTableResolverTests.swift
//  TableProTests
//

import Foundation
import Testing

@testable import TablePro

struct FavoriteTableResolverTests {
    private let connectionId = UUID()

    private func entry(_ name: String, schema: String?, database: String? = "shop") -> FavoriteTablesStorage.FavoriteEntry {
        FavoriteTablesStorage.FavoriteEntry(connectionId: connectionId, database: database, schema: schema, name: name)
    }

    private func table(_ name: String, schema: String?, type: TableInfo.TableType = .table) -> TableInfo {
        TableInfo(name: name, type: type, rowCount: nil, schema: schema)
    }

    private func source(
        _ tables: [TableInfo],
        schemas: Set<String>,
        isCurrent: Bool = true
    ) -> FavoriteTableCatalog.Source {
        FavoriteTableCatalog.Source(tables: tables, coverage: .schemas(schemas), isCurrent: isCurrent)
    }

    private func schemaScope(browsing schema: String? = "public") -> FavoriteTableBrowseScope {
        FavoriteTableBrowseScope(database: "shop", schema: schema, listsTablesPerSchema: true)
    }

    private func resolve(
        _ entries: [FavoriteTablesStorage.FavoriteEntry],
        scope: FavoriteTableBrowseScope? = nil,
        sources: [FavoriteTableCatalog.Source],
        search: String = ""
    ) -> FavoriteTableResolution {
        FavoriteTableResolver.resolve(
            entries,
            scope: scope ?? schemaScope(),
            catalog: FavoriteTableCatalog(sources: sources),
            search: SidebarSearch(search)
        )
    }

    @Test("A favorite in another schema that a current list holds is listed, verified, with its schema")
    func otherSchemaFavoriteIsListed() {
        let resolution = resolve(
            [entry("orders", schema: "sales")],
            sources: [
                source([table("users", schema: "public")], schemas: ["public"]),
                source([table("orders", schema: "sales")], schemas: ["sales"])
            ]
        )

        #expect(resolution.rows.count == 1)
        #expect(resolution.rows.first?.isVerified == true)
        #expect(resolution.rows.first?.otherSchema == "sales")
        #expect(resolution.missingCount == 0)
    }

    @Test("A favorite in the browsed schema carries no schema caption")
    func browsedSchemaFavoriteHasNoCaption() {
        let resolution = resolve(
            [entry("users", schema: "public")],
            sources: [source([table("users", schema: "public")], schemas: ["public"])]
        )

        #expect(resolution.rows.first?.otherSchema == nil)
    }

    @Test("A hierarchical engine lists a favorite from its own schema's list alone")
    func hierarchicalSchemaListIsEnough() {
        let resolution = resolve(
            [entry("EMPLOYEES", schema: "HR", database: nil)],
            scope: FavoriteTableBrowseScope(database: nil, schema: "SALES", listsTablesPerSchema: true),
            sources: [source([table("EMPLOYEES", schema: "HR")], schemas: ["HR"])]
        )

        #expect(resolution.rows.map(\.entry.name) == ["EMPLOYEES"])
        #expect(resolution.rows.first?.isVerified == true)
    }

    @Test("A favorite whose schema nothing has listed stays on the list, unverified")
    func unlistedSchemaKeepsTheFavorite() {
        let resolution = resolve(
            [entry("orders", schema: "sales")],
            sources: [source([table("users", schema: "public")], schemas: ["public"])]
        )

        #expect(resolution.rows.count == 1)
        #expect(resolution.rows.first?.isVerified == false)
        #expect(resolution.rows.first?.knownType == nil)
        #expect(resolution.rows.first?.table.type == .table)
    }

    @Test("A current list for the favorite's schema that lacks the table hides it")
    func currentListWithoutTheTableHidesIt() {
        let resolution = resolve(
            [entry("orders", schema: "sales")],
            sources: [source([table("invoices", schema: "sales")], schemas: ["sales"])]
        )

        #expect(resolution.rows.isEmpty)
        #expect(resolution.missingCount == 1)
    }

    @Test("A current list that lacks the table hides it even when a stale listing still holds it")
    func currentListOverridesAStaleListing() {
        let resolution = resolve(
            [entry("orders", schema: "sales")],
            sources: [
                source([table("orders", schema: "sales")], schemas: ["sales"], isCurrent: false),
                source([table("invoices", schema: "sales")], schemas: ["sales"])
            ]
        )

        #expect(resolution.rows.isEmpty)
        #expect(resolution.missingCount == 1)
    }

    @Test("A stale list without the table keeps the favorite, unverified")
    func staleListWithoutTheTableKeepsIt() {
        let resolution = resolve(
            [entry("orders", schema: "sales")],
            sources: [source([table("invoices", schema: "sales")], schemas: ["sales"], isCurrent: false)]
        )

        #expect(resolution.rows.count == 1)
        #expect(resolution.rows.first?.isVerified == false)
    }

    @Test("A stale list holding the table supplies its type to the unverified row")
    func staleListSuppliesTheType() {
        let resolution = resolve(
            [entry("active_orders", schema: "sales")],
            sources: [
                source([table("active_orders", schema: "sales", type: .view)], schemas: ["sales"], isCurrent: false)
            ]
        )

        #expect(resolution.rows.first?.isVerified == false)
        #expect(resolution.rows.first?.knownType == .view)
    }

    @Test("A current list's type wins over a stale one")
    func currentTypeWins() {
        let resolution = resolve(
            [entry("orders", schema: "sales")],
            sources: [
                source([table("orders", schema: "sales", type: .view)], schemas: ["sales"], isCurrent: false),
                source([table("orders", schema: "sales", type: .table)], schemas: ["sales"])
            ]
        )

        #expect(resolution.rows.first?.isVerified == true)
        #expect(resolution.rows.first?.knownType == .table)
    }

    @Test("Only a favorite a current list names as a writable kind opens editable")
    func onlyVerifiedWritableKindsOpenEditable() {
        let resolution = resolve(
            [
                entry("orders", schema: "sales"),
                entry("active_orders", schema: "sales"),
                entry("stock", schema: "inventory"),
                entry("audit", schema: "ops")
            ],
            sources: [
                source(
                    [table("orders", schema: "sales"), table("active_orders", schema: "sales", type: .view)],
                    schemas: ["sales"]
                ),
                source([table("stock", schema: "inventory")], schemas: ["inventory"], isCurrent: false)
            ]
        )
        let opensReadOnly = Dictionary(uniqueKeysWithValues: resolution.rows.map { ($0.entry.name, $0.opensReadOnly) })

        #expect(opensReadOnly == ["orders": false, "active_orders": true, "stock": true, "audit": true])
        #expect(resolution.rows.first { $0.entry.name == "stock" }?.verifiedType == nil)
    }

    @Test("A favorite from another database is not listed, and is counted as elsewhere")
    func otherDatabaseIsExcluded() {
        let resolution = resolve(
            [entry("orders", schema: "public", database: "warehouse")],
            sources: [source([table("orders", schema: "public")], schemas: ["public"])]
        )

        #expect(resolution.rows.isEmpty)
        #expect(resolution.otherDatabaseCount == 1)
        #expect(resolution.missingCount == 0)
    }

    @Test("The same table name in two schemas gives two rows with their own ids")
    func sameNameInTwoSchemas() {
        let resolution = resolve(
            [entry("orders", schema: "public"), entry("orders", schema: "sales")],
            sources: [
                source([table("orders", schema: "public")], schemas: ["public"]),
                source([table("orders", schema: "sales")], schemas: ["sales"])
            ]
        )

        #expect(resolution.rows.count == 2)
        #expect(Set(resolution.rows.map(\.id)).count == 2)
        #expect(resolution.rows.map(\.entry.schema) == ["public", "sales"])
    }

    @Test("Rows sort by name, then schema")
    func rowsSortByNameThenSchema() {
        let resolution = resolve(
            [entry("orders", schema: "sales"), entry("accounts", schema: "sales"), entry("orders", schema: "public")],
            sources: []
        )

        #expect(resolution.rows.map { "\($0.entry.schema ?? "").\($0.entry.name)" } == [
            "sales.accounts", "public.orders", "sales.orders"
        ])
    }

    @Test("A system schema the all-schema listing leaves out is not decided by that listing")
    func listingIsNotAuthorityForASystemSchema() {
        let listing = source([table("users", schema: "public")], schemas: ["public"], isCurrent: false)
        let resolution = resolve([entry("pg_stat_activity", schema: "pg_catalog")], sources: [listing])

        #expect(resolution.rows.count == 1)
        #expect(resolution.rows.first?.isVerified == false)
    }

    @Test("A current list of a system schema decides for it like any other")
    func currentSystemSchemaListDecides() {
        let catalog = source([table("pg_class", schema: "pg_catalog")], schemas: ["pg_catalog"])

        let listed = resolve([entry("pg_class", schema: "pg_catalog")], sources: [catalog])
        let missing = resolve([entry("pg_stat_activity", schema: "pg_catalog")], sources: [catalog])

        #expect(listed.rows.first?.isVerified == true)
        #expect(missing.rows.isEmpty)
    }

    @Test("An engine without per-schema lists hides a table its whole-database list lacks")
    func flatEngineListDecidesEverySchema() {
        let scope = FavoriteTableBrowseScope(database: "shop", schema: nil, listsTablesPerSchema: false)
        let flat = FavoriteTableCatalog.Source(
            tables: [table("users", schema: nil)],
            coverage: .everySchema,
            isCurrent: true
        )

        let resolution = resolve(
            [entry("users", schema: nil), entry("gone", schema: nil)],
            scope: scope,
            sources: [flat]
        )

        #expect(resolution.rows.map(\.entry.name) == ["users"])
        #expect(resolution.rows.first?.otherSchema == nil)
        #expect(resolution.missingCount == 1)
    }

    @Test("A plain search matches table names")
    func plainSearchMatchesNames() {
        let resolution = resolve(
            [entry("orders", schema: "sales"), entry("users", schema: "public")],
            sources: [],
            search: "ord"
        )

        #expect(resolution.rows.map(\.entry.name) == ["orders"])
    }

    @Test("A qualified search matches the schema as well as the name")
    func qualifiedSearchMatchesSchema() {
        let entries = [entry("orders", schema: "sales"), entry("orders", schema: "public"), entry("refunds", schema: "sales")]

        let wholeSchema = resolve(entries, sources: [], search: "sales.")
        let oneTable = resolve(entries, sources: [], search: "sales.ord")

        #expect(wholeSchema.rows.map(\.entry.name) == ["orders", "refunds"])
        #expect(wholeSchema.rows.allSatisfy { $0.entry.schema == "sales" })
        #expect(oneTable.rows.map(\.id) == [entry("orders", schema: "sales").id])
    }

    @Test("Only favorite schemas that no source has listed are asked for")
    func schemasNeedingLoadListsUncoveredSchemas() {
        let entries = [
            entry("users", schema: "public"),
            entry("orders", schema: "sales"),
            entry("stock", schema: "inventory"),
            entry("staged", schema: "etl", database: "warehouse")
        ]
        let catalog = FavoriteTableCatalog(sources: [
            source([table("users", schema: "public")], schemas: ["public"]),
            source([table("orders", schema: "sales")], schemas: ["sales"], isCurrent: false)
        ])

        let needed = FavoriteTableResolver.schemasNeedingLoad(entries, scope: schemaScope(), catalog: catalog)

        #expect(needed == ["inventory"])
    }

    @Test("An engine without per-schema lists never asks for a schema")
    func flatEngineNeedsNoLoad() {
        let scope = FavoriteTableBrowseScope(database: "shop", schema: nil, listsTablesPerSchema: false)

        let needed = FavoriteTableResolver.schemasNeedingLoad(
            [entry("orders", schema: "sales")],
            scope: scope,
            catalog: .empty
        )

        #expect(needed.isEmpty)
    }
}

private extension FavoriteTablesStorage.FavoriteEntry {
    var id: String {
        FavoritesOutlineNode.tableId(database: database, schema: schema, name: name)
    }
}
