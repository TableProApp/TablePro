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
        activeDatabase: String? = "app",
        activeSchema: String? = "public"
    ) -> DatabaseTreeMenuContext {
        DatabaseTreeMenuContext(
            clicked: clicked,
            selectedTables: selectedTables,
            selectedContainers: selectedContainers,
            activeDatabase: activeDatabase,
            activeSchema: activeSchema,
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
            showObjectIcons: true,
            showObjectComments: false,
            rowSize: .matchSystem
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

        #expect(!issued.contains(.truncateTables(["orders"])))
        #expect(!issued.contains(.dropTables(["orders"])))
        #expect(!issued.contains(.createView))
        #expect(issued.contains(.copyTableNames(["orders"])))
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
                routine: RoutineInfo(name: "do_thing", schema: "public", kind: .function, signature: nil)
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
