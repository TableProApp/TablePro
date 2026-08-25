//
//  DatabaseTreeMenuSpecTests.swift
//  TableProTests
//

import Foundation
import TableProPluginKit
import Testing

@testable import TablePro

@Suite("Database tree contextual menu")
struct DatabaseTreeMenuSpecTests {
    private func tableRef(_ name: String, type: TableInfo.TableType = .table) -> DatabaseTreeTableRef {
        DatabaseTreeTableRef(
            database: "app",
            schema: "public",
            table: TableInfo(name: name, type: type, rowCount: nil, schema: "public")
        )
    }

    private func context(
        clicked: DatabaseTreeNode.Kind?,
        selectedTables: Set<TableInfo> = [],
        selectedContainers: [DatabaseContainerRef] = [],
        isReadOnly: Bool = false,
        isFavorite: Bool = false,
        favoriteDatabaseEnvironments: [String: FavoriteDatabaseEnvironment] = [:],
        activeDatabase: String? = "app",
        activeSchema: String? = "public",
        canReachOtherDatabases: Bool = true,
        canFilterDatabases: Bool = false,
        hasDatabaseFilter: Bool = false
    ) -> DatabaseTreeMenuContext {
        DatabaseTreeMenuContext(
            clicked: clicked,
            selectedTables: selectedTables,
            selectedContainers: selectedContainers,
            activeDatabase: activeDatabase,
            activeSchema: activeSchema,
            canReachOtherDatabases: canReachOtherDatabases,
            systemSchemas: ["information_schema"],
            isReadOnly: isReadOnly,
            supportsImport: false,
            importFormats: [],
            maintenanceOperations: [],
            dropEligibility: ContainerDropEligibility.Context(
                activeDatabase: activeDatabase,
                activeSchema: activeSchema,
                supportsDropDatabase: true,
                supportsDropSchema: true,
                isReadOnly: isReadOnly
            ),
            containerEntityName: "Database",
            containerEntityNamePlural: "Databases",
            schemaEntityName: "Schema",
            schemaEntityNamePlural: "Schemas",
            objectKindTitles: [.table: "Tables"],
            isFavorite: isFavorite,
            favoriteDatabaseEnvironments: favoriteDatabaseEnvironments,
            showObjectIcons: true,
            showObjectComments: false,
            rowSize: .matchSystem,
            canFilterDatabases: canFilterDatabases,
            hasDatabaseFilter: hasDatabaseFilter
        )
    }

    private func commands(_ items: [DatabaseTreeMenuItem]) -> [SidebarMenuCommand] {
        items.flatMap { item -> [SidebarMenuCommand] in
            switch item {
            case .separator: return []
            case .command(let entry): return [entry.command]
            case .submenu(_, let nested): return commands(nested)
            }
        }
    }

    private func titles(_ items: [DatabaseTreeMenuItem]) -> [String] {
        items.compactMap { item in
            switch item {
            case .command(let entry): return entry.title
            case .submenu(let title, _): return title
            case .separator: return nil
            }
        }
    }

    // MARK: - The empty area

    /// A right-click below the last row used to produce nothing at all, which also made View
    /// Options unreachable whenever the sidebar was empty, loading or failed.
    @Test("Right-clicking the empty area still gives a menu")
    func emptyAreaHasAMenu() {
        let items = DatabaseTreeMenuSpec.items(for: context(clicked: nil))

        #expect(!items.isEmpty)
        #expect(titles(items).contains(String(localized: "View Options")))
    }

    @Test("A status row falls back to the empty-area menu rather than showing nothing")
    func statusRowUsesTheBackgroundMenu() {
        let items = DatabaseTreeMenuSpec.items(for: context(clicked: .status(.loading)))

        #expect(titles(items).contains(String(localized: "View Options")))
    }

    /// These moved out of the bar at the bottom of the sidebar, which the HIG reserves for nothing
    /// critical, so the background menu is now their only sidebar-local home.
    @Test("Creating objects is reachable from the empty area")
    func emptyAreaOffersCreation() {
        let issued = commands(DatabaseTreeMenuSpec.items(for: context(clicked: nil)))

        #expect(issued.contains(.createTable))
        #expect(issued.contains(.createView))
    }

    @Test("Read-only hides creation from the empty area too")
    func readOnlyEmptyAreaHidesCreation() {
        let issued = commands(DatabaseTreeMenuSpec.items(for: context(clicked: nil, isReadOnly: true)))

        #expect(!issued.contains(.createTable))
        #expect(!issued.contains(.createView))
    }

    @Test("A nested object group refresh carries its database and schema")
    func nestedObjectGroupRefreshIsScoped() {
        let group = DatabaseTreeObjectGroup(database: "archive", schema: "audit", kind: .view)
        let issued = commands(DatabaseTreeMenuSpec.items(
            for: context(clicked: .containerObjectKindSection(group))
        ))

        #expect(issued.contains(.refreshContainerObjectKind(group)))
        #expect(!issued.contains(.refreshObjectKind(.view)))
    }

    /// Export scopes the dialog to the database it was asked about, so a database other than the
    /// active one is offered wherever a second connection can reach it, and withheld where it
    /// cannot rather than opening a dialog listing something else.
    @Test("Exporting another database is offered only where the dialog can reach it")
    func exportOfferedOnlyWhereReachable() {
        let target = DatabaseContainerRef.database("analytics")
        let reachable = commands(DatabaseTreeMenuSpec.items(for: context(
            clicked: .database(DatabaseMetadata.minimal(name: "analytics")),
            selectedContainers: [target],
            activeDatabase: "app",
            canReachOtherDatabases: true
        )))
        let unreachable = commands(DatabaseTreeMenuSpec.items(for: context(
            clicked: .database(DatabaseMetadata.minimal(name: "analytics")),
            selectedContainers: [target],
            activeDatabase: "app",
            canReachOtherDatabases: false
        )))

        #expect(reachable.contains(.exportContainers([target])))
        #expect(!unreachable.contains(.exportContainers([target])))
    }

    @Test("The database filter is offered only where a database list exists")
    func filterOnlyWhereADatabaseListExists() {
        let tree = commands(DatabaseTreeMenuSpec.items(for: context(clicked: nil, canFilterDatabases: true)))
        let flat = commands(DatabaseTreeMenuSpec.items(for: context(clicked: nil, canFilterDatabases: false)))

        #expect(tree.contains(.filterDatabases))
        #expect(!flat.contains(.filterDatabases))
    }

    @Test("Show All Databases appears only when a filter is actually on")
    func showAllOnlyWhenFiltered() {
        let filtered = commands(DatabaseTreeMenuSpec.items(
            for: context(clicked: nil, canFilterDatabases: true, hasDatabaseFilter: true)
        ))
        let unfiltered = commands(DatabaseTreeMenuSpec.items(
            for: context(clicked: nil, canFilterDatabases: true, hasDatabaseFilter: false)
        ))

        #expect(filtered.contains(.showAllDatabases))
        #expect(!unfiltered.contains(.showAllDatabases))
    }

    @Test("View Options reports the settings it is toggling")
    func viewOptionsCarryTheirState() {
        let items = DatabaseTreeMenuSpec.viewOptionItems(context(clicked: nil))
        let icons = items.compactMap { item -> SidebarMenuEntry<SidebarMenuCommand>? in
            guard case .command(let entry) = item, entry.command == .toggleObjectIcons else { return nil }
            return entry
        }

        #expect(icons.first?.isOn == true)
    }

    // MARK: - Tables

    @Test("A table menu acts on the clicked table when it is outside the selection")
    func clickedTableOutsideSelectionActsOnItself() {
        let clicked = tableRef("orders")
        let items = DatabaseTreeMenuSpec.items(
            for: context(clicked: .table(clicked), selectedTables: [tableRef("users").table])
        )

        #expect(commands(items).contains(.copyTableNames(["orders"])))
    }

    @Test("A table menu acts on the whole selection when the clicked row is inside it")
    func clickedTableInsideSelectionActsOnAllOfIt() {
        let clicked = tableRef("orders")
        let items = DatabaseTreeMenuSpec.items(
            for: context(
                clicked: .table(clicked),
                selectedTables: [clicked.table, tableRef("users").table]
            )
        )

        #expect(commands(items).contains(.copyTableNames(["orders", "users"])))
    }

    @Test("Read-only hides the destructive items rather than dimming them")
    func readOnlyOmitsWrites() {
        let clicked = tableRef("orders")
        let items = DatabaseTreeMenuSpec.items(for: context(clicked: .table(clicked), isReadOnly: true))
        let issued = commands(items)

        #expect(!issued.contains(.truncateTables(names: ["orders"], ref: clicked)))
        #expect(!issued.contains(.dropTables(names: ["orders"], ref: clicked)))
        #expect(!issued.contains(.createView))
        #expect(issued.contains(.copyTableNames(["orders"])))
    }

    /// The session may be browsing a different database than the one the user right-clicked in, so
    /// every command that reaches the database carries the row it came from and switches there
    /// first. Without it, Truncate and Drop run against a same-named table somewhere else.
    @Test("Every command that reaches the database carries the row it was raised from")
    func databaseCommandsCarryTheirRow() {
        let elsewhere = DatabaseTreeTableRef(
            database: "reporting",
            schema: "public",
            table: TableInfo(name: "orders", type: .table, rowCount: nil, schema: "public")
        )
        let issued = commands(DatabaseTreeMenuSpec.items(for: context(clicked: .table(elsewhere))))

        #expect(issued.contains(.truncateTables(names: ["orders"], ref: elsewhere)))
        #expect(issued.contains(.dropTables(names: ["orders"], ref: elsewhere)))
        #expect(issued.contains(.exportTables(names: ["orders"], ref: elsewhere)))
    }

    @Test("The favourite item names the action it will take")
    func favouriteItemFlipsItsTitle() {
        let clicked = tableRef("orders")
        let add = DatabaseTreeMenuSpec.items(for: context(clicked: .table(clicked), isFavorite: false))
        let remove = DatabaseTreeMenuSpec.items(for: context(clicked: .table(clicked), isFavorite: true))

        #expect(titles(add).contains(String(localized: "Add to Favorites")))
        #expect(titles(remove).contains(String(localized: "Remove from Favorites")))
    }

    @Test("Only a view offers Edit View Definition")
    func editViewDefinitionIsViewOnly() {
        let view = tableRef("active_users", type: .view)
        let table = tableRef("users")

        #expect(commands(DatabaseTreeMenuSpec.items(for: context(clicked: .table(view))))
            .contains(.editViewDefinition(view)))
        #expect(!commands(DatabaseTreeMenuSpec.items(for: context(clicked: .table(table))))
            .contains(.editViewDefinition(table)))
    }

    // MARK: - Containers

    @Test("Use as Active is omitted for the container already in use")
    func activeContainerHasNoUseAsActive() {
        let items = DatabaseTreeMenuSpec.items(
            for: context(clicked: .schema(database: "app", schema: "public"))
        )

        #expect(!commands(items).contains { command in
            if case .useAsActive = command { return true }
            return false
        })
    }

    @Test("Use as Active is offered for a container that is not in use")
    func inactiveContainerOffersUseAsActive() {
        let items = DatabaseTreeMenuSpec.items(
            for: context(clicked: .schema(database: "app", schema: "billing"))
        )

        #expect(commands(items).contains { command in
            if case .useAsActive = command { return true }
            return false
        })
    }

    @Test("An unfavorited database offers every environment under Add to Favorites")
    func databaseCanBeFavoritedWithEnvironment() {
        let database = DatabaseMetadata.minimal(name: "analytics", isSystem: false)
        let items = DatabaseTreeMenuSpec.items(for: context(clicked: .database(database)))
        let issued = commands(items)

        #expect(titles(items).contains(String(localized: "Add to Favorites")))
        for environment in FavoriteDatabaseEnvironment.allCases {
            #expect(issued.contains(.setFavoriteDatabases(databases: ["analytics"], environment: environment)))
        }
        #expect(!issued.contains(.removeFavoriteDatabases(["analytics"])))
    }

    @Test("A favorite database can change environment or be removed")
    func favoriteDatabaseMenuReflectsState() {
        let database = DatabaseMetadata.minimal(name: "analytics", isSystem: false)
        let items = DatabaseTreeMenuSpec.items(for: context(
            clicked: .database(database),
            favoriteDatabaseEnvironments: ["analytics": .production]
        ))
        let issued = commands(items)

        #expect(titles(items).contains(String(localized: "Environment")))
        #expect(issued.contains(.removeFavoriteDatabases(["analytics"])))
        #expect(issued.contains(.setFavoriteDatabases(databases: ["analytics"], environment: .development)))
    }

    /// A right-click inside a multi-selection acts on the whole selection, which is what
    /// `NSTableView.clickedRow` documents and what `FieldDrivenList` already does. The favorite
    /// items used to disappear entirely once a second database was selected.
    @Test("A multi-database selection still offers the favorite items, for every database")
    func favoriteItemsSurviveMultiSelection() {
        let clicked = DatabaseMetadata.minimal(name: "analytics", isSystem: false)
        let items = DatabaseTreeMenuSpec.items(for: context(
            clicked: .database(clicked),
            selectedContainers: [
                .database("analytics", isSystem: false),
                .database("reporting", isSystem: false)
            ]
        ))
        let issued = commands(items)

        #expect(titles(items).contains(String(localized: "Add to Favorites")))
        #expect(issued.contains(
            .setFavoriteDatabases(databases: ["analytics", "reporting"], environment: .production)
        ))
    }

    /// Retagging is only what the menu offers when every target is already a favorite; a selection
    /// that mixes the two still says "Add to Favorites", and no environment is checked.
    @Test("A mixed selection offers Add to Favorites with no environment checked")
    func mixedSelectionOffersAdd() {
        let clicked = DatabaseMetadata.minimal(name: "analytics", isSystem: false)
        let items = DatabaseTreeMenuSpec.items(for: context(
            clicked: .database(clicked),
            selectedContainers: [
                .database("analytics", isSystem: false),
                .database("reporting", isSystem: false)
            ],
            favoriteDatabaseEnvironments: ["analytics": .production]
        ))

        #expect(titles(items).contains(String(localized: "Add to Favorites")))
        #expect(commands(items).contains(.removeFavoriteDatabases(["analytics", "reporting"])))
    }

    /// An engine with no database dimension names no database on its container refs, and a favorite
    /// that names nothing is unreachable.
    @Test("A schema row offers no favorite items")
    func schemaRowOffersNoFavoriteItems() {
        let items = DatabaseTreeMenuSpec.items(
            for: context(clicked: .schema(database: "app", schema: "public"))
        )

        #expect(!titles(items).contains(String(localized: "Add to Favorites")))
        #expect(!titles(items).contains(String(localized: "Environment")))
    }

    // MARK: - Shape

    @Test("A menu never opens or closes on a separator, and never doubles one")
    func separatorsAreCollapsed() {
        let kinds: [DatabaseTreeNode.Kind?] = [
            nil,
            .table(tableRef("orders")),
            .recentTable(tableRef("orders")),
            .schema(database: "app", schema: "billing"),
            .database(DatabaseMetadata.minimal(name: "app", isSystem: false)),
            .objectKindSection(.table),
            .status(.loading)
        ]

        for kind in kinds {
            let items = DatabaseTreeMenuSpec.items(for: context(clicked: kind, isReadOnly: false))
            #expect(items.first != .separator)
            #expect(items.last != .separator)
            for (previous, next) in zip(items, items.dropFirst()) {
                #expect(!(previous == .separator && next == .separator))
            }
        }
    }

    @Test("Every menu produces at least one item, so none opens as an empty frame")
    func everyMenuHasContent() {
        let kinds: [DatabaseTreeNode.Kind?] = [
            nil,
            .table(tableRef("orders")),
            .routine(DatabaseTreeRoutineRef(
                database: "app", schema: "public",
                routine: RoutineInfo(name: "do_thing", kind: .function, schema: "public")
            )),
            .status(.loading),
            .recentSection,
            .redisKeysSection
        ]

        for kind in kinds {
            #expect(!DatabaseTreeMenuSpec.items(for: context(clicked: kind, isReadOnly: true)).isEmpty)
        }
    }
}
