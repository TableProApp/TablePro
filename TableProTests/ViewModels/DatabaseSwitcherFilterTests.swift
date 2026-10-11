//
//  DatabaseSwitcherFilterTests.swift
//  TableProTests
//

import Foundation
@testable import TablePro
import Testing

@MainActor
struct DatabaseSwitcherFilterTests {
    private func makeViewModel(
        databaseNames: [String],
        filter: Set<String> = [],
        systemNames: [String] = [],
        switchTarget: ContainerSwitchTarget = .database,
        currentDatabase: String? = nil
    ) -> DatabaseSwitcherViewModel {
        let sidebarState = SharedSidebarState()
        sidebarState.databaseFilterSelected = filter
        let vm = DatabaseSwitcherViewModel(
            connectionId: UUID(),
            currentDatabase: currentDatabase,
            databaseType: .mysql,
            switchTarget: switchTarget,
            sidebarState: sidebarState
        )
        vm.databases = databaseNames.map { name in
            DatabaseMetadata.minimal(name: name, isSystem: systemNames.contains(name))
        }
        return vm
    }

    @Test("Empty search returns every database")
    func emptySearchReturnsAll() {
        let vm = makeViewModel(databaseNames: ["app", "analytics", "staging"])
        #expect(vm.filteredDatabases.count == 3)
    }

    @Test("Search matches subsequences, not just substrings")
    func searchMatchesSubsequence() {
        let vm = makeViewModel(databaseNames: ["analytics_prod", "staging"])
        vm.searchText = "anprd"
        #expect(vm.filteredDatabases.map(\.name) == ["analytics_prod"])
    }

    @Test("Better matches rank first")
    func betterMatchesRankFirst() {
        let vm = makeViewModel(databaseNames: ["my_app_db", "app"])
        vm.searchText = "app"
        #expect(vm.filteredDatabases.first?.name == "app")
    }

    @Test("Non-matching search returns nothing")
    func nonMatchingSearchReturnsNothing() {
        let vm = makeViewModel(databaseNames: ["app", "analytics"])
        vm.searchText = "zzz"
        #expect(vm.filteredDatabases.isEmpty)
    }

    @Test("Sidebar filter narrows the database list to the selected set")
    func sidebarFilterNarrowsList() {
        let vm = makeViewModel(
            databaseNames: ["app", "analytics", "staging", "logs"],
            filter: ["app", "staging"]
        )
        #expect(Set(vm.filteredDatabases.map(\.name)) == ["app", "staging"])
    }

    /// #2832. A MySQL server listed `mysql`, `sys` and the rest, and the switcher dropped every one of
    /// them, so a user who connected with no database could never reach `mysql`.
    @Test("System databases are listed after the user databases")
    func systemDatabasesAreListedLast() {
        let vm = makeViewModel(
            databaseNames: ["analytics", "app", "mysql", "staging", "sys"],
            systemNames: ["mysql", "sys"]
        )
        #expect(vm.filteredDatabases.map(\.name) == ["analytics", "app", "staging", "mysql", "sys"])
        #expect(vm.visibleSections.system.map(\.name) == ["mysql", "sys"])
    }

    @Test("The sidebar filter never hides a system database")
    func sidebarFilterKeepsSystemDatabases() {
        let vm = makeViewModel(
            databaseNames: ["app", "mysql", "staging", "sys"],
            filter: ["app"],
            systemNames: ["mysql", "sys"]
        )
        #expect(vm.filteredDatabases.map(\.name) == ["app", "mysql", "sys"])
    }

    @Test("Typing a system database's name finds and selects it")
    func typingSystemDatabaseNameFindsIt() {
        let vm = makeViewModel(databaseNames: ["app", "mysql"], systemNames: ["mysql"])
        vm.searchText = "mysql"
        #expect(vm.filteredDatabases.map(\.name) == ["mysql"])
        #expect(vm.selectedDatabase == "mysql")
    }

    @Test("A search ranks within each section, so a system database never outranks a user database")
    func searchRanksWithinSections() {
        let vm = makeViewModel(databaseNames: ["mysql", "mysql_backup"], systemNames: ["mysql"])
        vm.searchText = "mysql"
        #expect(vm.filteredDatabases.map(\.name) == ["mysql_backup", "mysql"])
    }

    @Test("The arrow keys walk from the last user database into the system section")
    func arrowKeysReachSystemSection() {
        let vm = makeViewModel(databaseNames: ["app", "mysql", "staging"], systemNames: ["mysql"])
        vm.selectedDatabase = "staging"
        vm.moveDown()
        #expect(vm.selectedDatabase == "mysql")
    }

    @Test("Schema mode lists system schemas last and ignores the database filter")
    func schemaModeListsSystemSchemasLast() {
        let vm = makeViewModel(
            databaseNames: ["APP", "SYS", "SALES"],
            filter: ["APP"],
            systemNames: ["SYS"],
            switchTarget: .schema
        )
        #expect(vm.filteredDatabases.map(\.name) == ["APP", "SALES", "SYS"])
    }

    private func makeSchemaViewModel(
        schemaNames: [String],
        systemNames: [String] = [],
        currentSchema: String? = nil,
        activeDatabase: String?,
        keptSchemas: [String: Set<String>]
    ) -> DatabaseSwitcherViewModel {
        let vm = DatabaseSwitcherViewModel(
            connectionId: UUID(),
            currentDatabase: currentSchema,
            databaseType: .mysql,
            switchTarget: .schema,
            activeDatabase: activeDatabase,
            sidebarState: SharedSidebarState(),
            keptSchemas: { _, database in keptSchemas[database] }
        )
        vm.databases = schemaNames.map { name in
            DatabaseMetadata.minimal(name: name, isSystem: systemNames.contains(name))
        }
        return vm
    }

    @Test("Schema mode lists the schemas the sidebar's schema filter keeps, with system schemas and the current one")
    func schemaModeFollowsTheSchemaFilter() {
        let vm = makeSchemaViewModel(
            schemaNames: ["APP", "HR", "SALES", "SYS"],
            systemNames: ["SYS"],
            currentSchema: "APP",
            activeDatabase: "ORCL",
            keptSchemas: ["ORCL": ["SALES"]]
        )
        #expect(vm.filteredDatabases.map(\.name) == ["APP", "SALES", "SYS"])
    }

    @Test("Schema mode reads the filter of the database its schemas belong to")
    func schemaModeReadsTheActiveDatabaseFilter() {
        let vm = makeSchemaViewModel(
            schemaNames: ["APP", "HR", "SALES"],
            activeDatabase: "ORCL",
            keptSchemas: ["OTHER": ["SALES"]]
        )
        #expect(vm.filteredDatabases.map(\.name) == ["APP", "HR", "SALES"])
    }

    @Test("Schema mode with no database to read a filter for lists every schema")
    func schemaModeWithoutDatabaseIsUnfiltered() {
        let vm = makeSchemaViewModel(
            schemaNames: ["APP", "HR", "SALES"],
            activeDatabase: nil,
            keptSchemas: ["": ["SALES"]]
        )
        #expect(vm.filteredDatabases.map(\.name) == ["APP", "HR", "SALES"])
    }
}
