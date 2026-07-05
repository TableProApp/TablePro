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
        let visible = DatabaseTreeVisibility.visible(databases: databases, selected: [])
        #expect(visible.map(\.name) == ["analytics", "billing", "legacy_2019"])
    }

    @Test("Non-empty selection shows only the selected non-system databases")
    func selectionShowsSubset() {
        let visible = DatabaseTreeVisibility.visible(databases: databases, selected: ["billing", "legacy_2019"])
        #expect(visible.map(\.name) == ["billing", "legacy_2019"])
    }

    @Test("System databases are never shown even when selected")
    func systemNeverShown() {
        let visible = DatabaseTreeVisibility.visible(databases: databases, selected: ["mysql", "analytics"])
        #expect(visible.map(\.name) == ["analytics"])
    }

    @Test("Selecting a database that no longer exists yields an empty result")
    func staleSelectionEmpty() {
        let visible = DatabaseTreeVisibility.visible(databases: databases, selected: ["dropped_db"])
        #expect(visible.isEmpty)
    }

    @Test("isFiltering reflects whether a selection is active")
    func isFiltering() {
        #expect(DatabaseTreeVisibility.isFiltering(selected: []) == false)
        #expect(DatabaseTreeVisibility.isFiltering(selected: ["analytics"]))
    }
}
