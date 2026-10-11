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

    // MARK: - Schema filter

    private let schemas = ["public", "sales", "hr", "audit", "pg_catalog"]
    private let systemSchemas: Set<String> = ["pg_catalog"]

    private func visibleSchemas(
        selected: Set<String>,
        active: String? = nil,
        showsSystem: Bool = false,
        pinned: Set<String> = []
    ) -> [String] {
        DatabaseTreeVisibility.visibleSchemas(
            schemas,
            systemSchemas: systemSchemas,
            activeSchema: active,
            showsSystem: showsSystem,
            selected: selected,
            pinned: pinned
        )
    }

    @Test("A schema filter keeps the schemas it names and the active one")
    func schemaFilterKeepsSelectionAndActive() {
        #expect(visibleSchemas(selected: ["sales", "hr"], active: "public") == ["public", "sales", "hr"])
    }

    @Test("A schema holding a staged operation stays listed whatever the filter says")
    func schemaFilterKeepsPinnedSchemas() {
        #expect(visibleSchemas(selected: ["sales"], pinned: ["audit"]) == ["sales", "audit"])
    }

    @Test("A schema filter of hidden system schemas only is no filter")
    func schemaFilterOfHiddenSystemSchemasShowsEverything() {
        #expect(visibleSchemas(selected: ["pg_catalog"]) == ["public", "sales", "hr", "audit"])
        #expect(DatabaseTreeVisibility.keptSchemas(
            selected: ["pg_catalog"], schemas: schemas, systemSchemas: systemSchemas, showsSystem: false, activeSchema: "public"
        ) == nil)
    }

    @Test("A schema filter of dropped schemas only is no filter")
    func schemaFilterOfDroppedSchemasShowsEverything() {
        #expect(visibleSchemas(selected: ["archive_2019"]) == ["public", "sales", "hr", "audit"])
        #expect(DatabaseTreeVisibility.isFilteringSchemas(
            selected: ["archive_2019"], schemas: schemas, systemSchemas: systemSchemas, showsSystem: false
        ) == false)
    }

    @Test("While the schema list is unknown a selection counts as given, less hidden system names")
    func schemaFilterWithUnknownList() {
        #expect(DatabaseTreeVisibility.keptSchemas(
            selected: ["archive_2019", "pg_catalog"], schemas: nil, systemSchemas: systemSchemas,
            showsSystem: false, activeSchema: nil
        ) == ["archive_2019"])
    }

    @Test("The kept set is nil for no filter and adds the active schema otherwise")
    func keptSchemas() {
        #expect(DatabaseTreeVisibility.keptSchemas(
            selected: [], schemas: schemas, systemSchemas: systemSchemas, showsSystem: false, activeSchema: "public"
        ) == nil)
        #expect(DatabaseTreeVisibility.keptSchemas(
            selected: ["sales"], schemas: schemas, systemSchemas: systemSchemas, showsSystem: false, activeSchema: "public"
        ) == ["sales", "public"])
        #expect(DatabaseTreeVisibility.keptSchemas(
            selected: ["sales"], schemas: schemas, systemSchemas: systemSchemas, showsSystem: false, activeSchema: ""
        ) == ["sales"])
    }

    @Test("The schema summary counts the selection, never the active schema it did not pick")
    func schemaSummaryExcludesActiveSchema() {
        let summary = DatabaseTreeVisibility.schemaSummary(
            schemas: schemas, selected: ["sales", "hr"], systemSchemas: systemSchemas, showsSystem: false
        )
        #expect(summary == .init(shown: 2, total: 4))
        #expect(DatabaseTreeVisibility.schemaFilterCandidates(schemas, systemSchemas: systemSchemas, showsSystem: true)
            == schemas)
    }

    @Test("With system schemas shown, the schema filter selects them like any other")
    func schemaFilterSelectsSystemSchemasWhenShown() {
        #expect(visibleSchemas(selected: ["pg_catalog", "hr"], showsSystem: true) == ["hr", "pg_catalog"])
    }
}
