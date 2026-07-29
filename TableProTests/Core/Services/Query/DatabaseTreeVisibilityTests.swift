@testable import TablePro
import Testing

@Suite("DatabaseTreeVisibility")
struct DatabaseTreeVisibilityTests {
    private let databases: [DatabaseMetadata] = [
        .minimal(name: "analytics"),
        .minimal(name: "billing"),
        .minimal(name: "legacy_2019"),
        .minimal(name: "mysql", isSystem: true),
        .minimal(name: "information_schema", isSystem: true)
    ]

    @Test("Empty selection shows all non-system databases")
    func emptyShowsAll() {
        let visible = DatabaseTreeVisibility.visible(databases: databases, selected: [], activeDatabase: nil)
        #expect(visible.map(\.name) == ["analytics", "billing", "legacy_2019"])
    }

    @Test("Non-empty selection shows only the selected non-system databases")
    func selectionShowsSubset() {
        let visible = DatabaseTreeVisibility.visible(
            databases: databases,
            selected: ["billing", "legacy_2019"],
            activeDatabase: nil
        )
        #expect(visible.map(\.name) == ["billing", "legacy_2019"])
    }

    @Test("System databases are hidden even when selected")
    func systemHiddenWhenSelected() {
        let visible = DatabaseTreeVisibility.visible(
            databases: databases,
            selected: ["mysql", "analytics"],
            activeDatabase: nil
        )
        #expect(visible.map(\.name) == ["analytics"])
    }

    @Test("Selecting a database that no longer exists yields an empty result")
    func staleSelectionEmpty() {
        let visible = DatabaseTreeVisibility.visible(databases: databases, selected: ["dropped_db"], activeDatabase: nil)
        #expect(visible.isEmpty)
    }

    @Test("The active database stays visible even when it is a system database")
    func activeSystemDatabaseStaysVisible() {
        let visible = DatabaseTreeVisibility.visible(databases: databases, selected: [], activeDatabase: "mysql")
        #expect(visible.map(\.name) == ["analytics", "billing", "legacy_2019", "mysql"])
    }

    @Test("The active database stays visible when the filter excludes it")
    func activeDatabaseSurvivesFilter() {
        let visible = DatabaseTreeVisibility.visible(
            databases: databases,
            selected: ["billing"],
            activeDatabase: "analytics"
        )
        #expect(visible.map(\.name) == ["analytics", "billing"])
    }

    @Test("The active database keeps its position in the list")
    func activeDatabaseKeepsPosition() {
        let visible = DatabaseTreeVisibility.visible(
            databases: databases,
            selected: [],
            activeDatabase: "information_schema"
        )
        #expect(visible.map(\.name) == ["analytics", "billing", "legacy_2019", "information_schema"])
    }

    @Test("An empty active database name is treated as absent")
    func emptyActiveDatabaseIgnored() {
        let visible = DatabaseTreeVisibility.visible(databases: databases, selected: [], activeDatabase: "")
        #expect(visible.map(\.name) == ["analytics", "billing", "legacy_2019"])
    }

    @Test("isFiltering reflects whether a selection is active")
    func isFiltering() {
        #expect(DatabaseTreeVisibility.isFiltering(selected: []) == false)
        #expect(DatabaseTreeVisibility.isFiltering(selected: ["analytics"]))
    }
}
