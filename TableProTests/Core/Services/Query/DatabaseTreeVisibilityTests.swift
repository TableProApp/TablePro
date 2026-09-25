@testable import TablePro
import Testing

struct DatabaseTreeVisibilityTests {
    private let databases: [DatabaseMetadata] = [
        .minimal(name: "analytics"),
        .minimal(name: "billing"),
        .minimal(name: "legacy_2019"),
        .minimal(name: "mysql", isSystem: true),
        .minimal(name: "information_schema", isSystem: true)
    ]

    private func visible(
        selected: Set<String> = [],
        activeDatabase: String? = nil,
        showsSystem: Bool = false
    ) -> [String] {
        DatabaseTreeVisibility.visible(
            databases: databases,
            selected: selected,
            activeDatabase: activeDatabase,
            showsSystem: showsSystem
        ).map(\.name)
    }

    private func summary(selected: Set<String>, showsSystem: Bool = false) -> DatabaseTreeVisibility.Summary {
        DatabaseTreeVisibility.summary(databases: databases, selected: selected, showsSystem: showsSystem)
    }

    @Test("Empty selection shows all non-system databases while system databases are hidden")
    func emptyShowsAll() {
        #expect(visible() == ["analytics", "billing", "legacy_2019"])
    }

    @Test("Showing system databases lists them in place")
    func showsSystemDatabases() {
        #expect(visible(showsSystem: true) == ["analytics", "billing", "legacy_2019", "mysql", "information_schema"])
    }

    @Test("Non-empty selection shows only the selected non-system databases")
    func selectionShowsSubset() {
        #expect(visible(selected: ["billing", "legacy_2019"]) == ["billing", "legacy_2019"])
    }

    @Test("A hidden system database in the selection is set aside")
    func hiddenSystemDatabaseInSelectionIsSetAside() {
        #expect(visible(selected: ["mysql", "analytics"]) == ["analytics"])
    }

    @Test("A filter naming only hidden system databases does not blank the tree")
    func filterOfHiddenSystemDatabasesShowsEverything() {
        #expect(visible(selected: ["mysql"]) == ["analytics", "billing", "legacy_2019"])
        #expect(DatabaseTreeVisibility.isFiltering(selected: ["mysql"], databases: databases, showsSystem: false) == false)
    }

    @Test("With system databases shown, the filter selects them like any other database")
    func filterSelectsSystemDatabasesWhenShown() {
        #expect(visible(selected: ["mysql", "analytics"], showsSystem: true) == ["analytics", "mysql"])
        #expect(DatabaseTreeVisibility.isFiltering(selected: ["mysql"], databases: databases, showsSystem: true))
    }

    @Test("Selecting a database that no longer exists yields an empty result")
    func staleSelectionEmpty() {
        #expect(visible(selected: ["dropped_db"]).isEmpty)
        #expect(DatabaseTreeVisibility.isFiltering(selected: ["dropped_db"], databases: databases, showsSystem: false))
    }

    @Test("The active database stays visible even when it is a hidden system database")
    func activeSystemDatabaseStaysVisible() {
        #expect(visible(activeDatabase: "mysql") == ["analytics", "billing", "legacy_2019", "mysql"])
    }

    @Test("The active database stays visible when the filter excludes it")
    func activeDatabaseSurvivesFilter() {
        #expect(visible(selected: ["billing"], activeDatabase: "analytics") == ["analytics", "billing"])
    }

    @Test("The active database keeps its position in the list")
    func activeDatabaseKeepsPosition() {
        #expect(visible(activeDatabase: "information_schema") == ["analytics", "billing", "legacy_2019", "information_schema"])
    }

    @Test("An empty active database name is treated as absent")
    func emptyActiveDatabaseIgnored() {
        #expect(visible(activeDatabase: "") == ["analytics", "billing", "legacy_2019"])
    }

    @Test("isFiltering reflects whether a selection is active")
    func isFiltering() {
        #expect(DatabaseTreeVisibility.isFiltering(selected: [], databases: databases, showsSystem: false) == false)
        #expect(DatabaseTreeVisibility.isFiltering(selected: ["analytics"], databases: databases, showsSystem: false))
    }

    @Test("The filter offers system databases only while they are shown")
    func filterCandidatesFollowTheSetting() {
        #expect(DatabaseTreeVisibility.filterCandidates(databases, showsSystem: false).map(\.name)
            == ["analytics", "billing", "legacy_2019"])
        #expect(DatabaseTreeVisibility.filterCandidates(databases, showsSystem: true).count == 5)
    }

    @Test("The summary counts what the filter picks out of what it could pick")
    func summaryCountsSelectedCandidates() {
        #expect(summary(selected: []) == .init(shown: 3, total: 3))
        #expect(summary(selected: ["analytics"]) == .init(shown: 1, total: 3))
        #expect(summary(selected: ["mysql"], showsSystem: true) == .init(shown: 1, total: 5))
    }

    @Test("The summary never counts a hidden system database, so it cannot exceed its total")
    func summaryIgnoresHiddenSystemDatabases() {
        #expect(summary(selected: ["mysql", "billing"]) == .init(shown: 1, total: 3))
    }

    @Test("System schemas are hidden unless shown")
    func systemSchemasFollowTheSetting() {
        let schemas = ["public", "pg_catalog", "sales"]
        let hidden = DatabaseTreeVisibility.visibleSchemas(
            schemas, systemSchemas: ["pg_catalog"], activeSchema: nil, showsSystem: false
        )
        let shown = DatabaseTreeVisibility.visibleSchemas(
            schemas, systemSchemas: ["pg_catalog"], activeSchema: nil, showsSystem: true
        )
        #expect(hidden == ["public", "sales"])
        #expect(shown == schemas)
    }

    @Test("The schema being browsed stays listed while system schemas are hidden")
    func activeSystemSchemaStaysListed() {
        let visible = DatabaseTreeVisibility.visibleSchemas(
            ["APP", "SYS", "CTISYS"],
            systemSchemas: ["SYS", "CTISYS"],
            activeSchema: "CTISYS",
            showsSystem: false
        )
        #expect(visible == ["APP", "CTISYS"])
    }

    @Test("An empty active schema name is treated as absent")
    func emptyActiveSchemaIgnored() {
        let visible = DatabaseTreeVisibility.visibleSchemas(
            ["public", "information_schema"],
            systemSchemas: ["information_schema"],
            activeSchema: "",
            showsSystem: false
        )
        #expect(visible == ["public"])
    }
}
