@testable import TablePro
import Testing

@Suite("DatabaseSwitchList")
struct DatabaseSwitchListTests {
    private let databases: [DatabaseMetadata] = [
        .minimal(name: "analytics"),
        .minimal(name: "billing"),
        .minimal(name: "legacy_2019"),
        .minimal(name: "mysql", isSystem: true),
        .minimal(name: "information_schema", isSystem: true)
    ]

    private func sections(selected: Set<String> = [], activeDatabase: String? = nil) -> DatabaseSwitchSections {
        DatabaseSwitchList.sections(databases: databases, selected: selected, activeDatabase: activeDatabase)
    }

    @Test("System databases trail in their own section")
    func systemDatabasesTrail() {
        let result = sections()
        #expect(result.user.map(\.name) == ["analytics", "billing", "legacy_2019"])
        #expect(result.system.map(\.name) == ["mysql", "information_schema"])
        #expect(result.all.map(\.name) == ["analytics", "billing", "legacy_2019", "mysql", "information_schema"])
    }

    @Test("The sidebar filter narrows user databases and never hides a system database")
    func filterNarrowsUserDatabasesOnly() {
        let result = sections(selected: ["billing"])
        #expect(result.user.map(\.name) == ["billing"])
        #expect(result.system.map(\.name) == ["mysql", "information_schema"])
    }

    @Test("The active database stays listed when the filter excludes it")
    func activeDatabaseSurvivesFilter() {
        #expect(sections(selected: ["billing"], activeDatabase: "analytics").user.map(\.name) == ["analytics", "billing"])
    }

    @Test("A filter that names no listed user database leaves every user database listed")
    func filterWithoutUserDatabasesListsThemAll() {
        let result = sections(selected: ["dropped_db", "mysql"])
        #expect(result.user.map(\.name) == ["analytics", "billing", "legacy_2019"])
    }

    @Test("An active system database stays in the system section")
    func activeSystemDatabaseStaysInSystemSection() {
        let result = sections(selected: ["billing"], activeDatabase: "mysql")
        #expect(result.user.map(\.name) == ["billing"])
        #expect(result.system.map(\.name) == ["mysql", "information_schema"])
    }

    @Test("Fetched names are split by the engine's system list, in the order the server returned them")
    func namesAreClassifiedBySystemList() {
        let result = DatabaseSwitchList.sections(
            names: ["sys", "app", "mysql"],
            systemNames: ["mysql", "sys"],
            selected: [],
            activeDatabase: nil
        )
        #expect(result.user.map(\.name) == ["app"])
        #expect(result.system.map(\.name) == ["sys", "mysql"])
        let everySystemRowIsFlagged = result.system.allSatisfy(\.isSystemDatabase)
        #expect(everySystemRowIsFlagged)
    }

    @Test("Nothing to list reports empty")
    func emptyWhenNothingToList() {
        #expect(DatabaseSwitchList.sections(databases: [], selected: [], activeDatabase: nil).isEmpty)
    }
}
