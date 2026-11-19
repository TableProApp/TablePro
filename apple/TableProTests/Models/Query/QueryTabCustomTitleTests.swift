import Foundation
@testable import TablePro
import Testing

@MainActor
struct QueryTabCustomTitleTests {
    private func makeManager(tabCount: Int = 2) -> QueryTabManager {
        let manager = QueryTabManager()
        for _ in 0..<tabCount {
            manager.addTab()
        }
        return manager
    }

    private func namedTab(_ name: String, automatic: String, query: String = "") -> QueryTab {
        var tab = QueryTab(title: name, query: query, tabType: .query)
        tab.automaticTitle = automatic
        return tab
    }

    private func tab(_ id: UUID, in manager: QueryTabManager) throws -> QueryTab {
        try #require(manager.tabs.first { $0.id == id })
    }

    // MARK: - Naming and clearing

    @Test("A name shows in place of the title, which is kept to go back to")
    func nameKeepsTheAutomaticTitle() throws {
        let manager = makeManager()
        let id = manager.tabs[1].id

        manager.renameTab(id: id, to: "Monthly report")

        let named = try tab(id, in: manager)
        #expect(named.title == "Monthly report")
        #expect(named.automaticTitle == "Query 2")
        #expect(named.isNamedByUser)
        #expect(named.automaticName == "Query 2")
    }

    @Test("Naming a named tab again keeps the title it first had")
    func secondNameKeepsTheFirstAutomaticTitle() throws {
        let manager = makeManager()
        let id = manager.tabs[1].id

        manager.renameTab(id: id, to: "Draft")
        manager.renameTab(id: id, to: "Monthly report")

        let named = try tab(id, in: manager)
        #expect(named.title == "Monthly report")
        #expect(named.automaticTitle == "Query 2")
    }

    @Test("An empty name goes back to the title the tab had")
    func emptyNameGoesBack() throws {
        let manager = makeManager()
        let id = manager.tabs[1].id
        manager.renameTab(id: id, to: "Monthly report")

        manager.renameTab(id: id, to: " \n\t ")

        let cleared = try tab(id, in: manager)
        #expect(cleared.title == "Query 2")
        #expect(cleared.automaticTitle == nil)
        #expect(!cleared.isNamedByUser)
    }

    @Test("A typed name is stored on one line, trimmed")
    func typedNameIsNormalized() throws {
        let manager = makeManager()
        let id = manager.tabs[0].id

        manager.renameTab(id: id, to: "  Q3\r\nreport\t")

        #expect(try tab(id, in: manager).title == "Q3 report")
    }

    @Test("A named tab keeps its number, so a new tab never takes it and clearing brings it back")
    func namedTabKeepsItsNumber() throws {
        let manager = makeManager()
        let id = manager.tabs[1].id
        manager.renameTab(id: id, to: "Report")

        manager.addTab()
        manager.renameTab(id: id, to: "")

        #expect(manager.tabs.map(\.title) == ["Query 1", "Query 2", "Query 3"])
    }

    @Test("Clearing a name whose number another tab took meanwhile takes the next free one")
    func clearingTakesAFreeNumberWhenItsOwnIsTaken() throws {
        let manager = QueryTabManager()
        let named = namedTab("Report", automatic: "Query 1")
        manager.tabs = [named, QueryTab(title: "Query 1", tabType: .query)]

        manager.renameTab(id: named.id, to: "")

        #expect(try tab(named.id, in: manager).title == "Query 2")
    }

    @Test("Clearing back to a title that is not a number keeps it even when another tab shares it")
    func clearingKeepsASharedTitleThatIsNotANumber() throws {
        let manager = QueryTabManager()
        let named = namedTab("Report", automatic: "Monthly report")
        manager.tabs = [named, QueryTab(title: "Monthly report", tabType: .query)]

        manager.renameTab(id: named.id, to: "")

        #expect(try tab(named.id, in: manager).title == "Monthly report")
    }

    @Test("A rename marks the tab renamed, and emptying an unnamed tab's name changes nothing")
    func renameMarksTheTabRenamed() throws {
        let manager = makeManager()
        let id = manager.tabs[0].id
        let before = manager.tabStructureVersion

        manager.renameTab(id: id, to: "")
        #expect(manager.tabStructureVersion == before)
        #expect(try tab(id, in: manager).title == "Query 1")

        manager.renameTab(id: id, to: "Report")
        #expect(manager.tabStructureVersion == before + 1)
    }

    @Test("Only a query tab with no file can be renamed")
    func onlyUnboundQueryTabsCanBeRenamed() {
        let manager = QueryTabManager()
        var file = QueryTab(title: "report.sql", query: "SELECT 1", tabType: .query)
        file.content.sourceFileURL = URL(fileURLWithPath: "/tmp/report.sql")
        let table = QueryTab(title: "users", tabType: .table, tableName: "users")
        let query = QueryTab(title: "Query 1", tabType: .query)
        manager.tabs = [file, table, query]

        manager.renameTab(id: file.id, to: "Mine")
        manager.renameTab(id: table.id, to: "Mine")

        #expect(!file.canBeRenamed)
        #expect(!table.canBeRenamed)
        #expect(query.canBeRenamed)
        #expect(manager.tabs.map(\.title) == ["report.sql", "users", "Query 1"])
        #expect(manager.tabs.allSatisfy { !$0.isNamedByUser })
    }

    @Test("Rename is offered only for a query tab on a strip of two or more")
    func renameNeedsTwoTabsOnTheStrip() throws {
        let manager = makeManager(tabCount: 1)
        let first = manager.tabs[0].id
        #expect(!manager.canRenameTab(id: first))

        manager.addTab()
        try manager.addTableTab(tableName: "users", databaseType: .mysql)
        let table = try #require(manager.selectedTabId)

        #expect(manager.canRenameTab(id: first))
        #expect(!manager.canRenameTab(id: table))
        #expect(!manager.canRenameTab(id: UUID()))
    }

    @Test("A caller's Query N title stays automatic, so a repeat of it can still be renumbered")
    func callerDefaultTitleStaysAutomatic() throws {
        let manager = QueryTabManager()

        manager.addTab(title: "Query 7")

        let added = try #require(manager.selectedTab)
        #expect(added.automaticTitle == nil)
        #expect(added.renumbersOnCollision)
    }

    @Test("A tab the browser takes over as a table tab loses its name")
    func retargetedTabLosesItsName() throws {
        let manager = makeManager()
        let id = manager.tabs[1].id
        manager.renameTab(id: id, to: "Report")
        manager.selectedTabId = id

        #expect(try manager.replaceTabContent(tableName: "users", databaseType: .mysql))

        let retargeted = try tab(id, in: manager)
        #expect(retargeted.tabType == .table)
        #expect(retargeted.title == "users")
        #expect(retargeted.automaticTitle == nil)
    }

    @Test("A linked file takes over only a blank, unnamed tab with no file")
    func linkedFileAdoptsOnlyAnUntouchedTab() {
        var file = QueryTab(title: "a.sql", tabType: .query)
        file.content.sourceFileURL = URL(fileURLWithPath: "/tmp/a.sql")

        #expect(QueryTab(title: "Query 1", query: " \n", tabType: .query).canAdoptLinkedFile)
        #expect(!namedTab("Report", automatic: "Query 1").canAdoptLinkedFile)
        #expect(!QueryTab(title: "Query 1", query: "SELECT 1", tabType: .query).canAdoptLinkedFile)
        #expect(!file.canAdoptLinkedFile)
    }

    // MARK: - Numbering

    @Test("The next number counts a named tab's automatic title")
    func nextNumberCountsAutomaticTitles() {
        let tabs = [QueryTab(title: "Query 1", tabType: .query), namedTab("Report", automatic: "Query 5")]

        #expect(QueryTabManager.nextQueryTitle(existingTabs: tabs) == "Query 6")
    }

    // Number only: the title path trapped on today's code and would take the shared test host with it.
    @Test("The next number skips the largest Int, which one more would overflow")
    func nextNumberSkipsTheLargestInt() {
        let largest = QueryTab(title: "Query \(Int.max)", tabType: .query)
        let namedLargest = namedTab("Report", automatic: "Query \(Int.max)")

        #expect(QueryTabManager.nextQueryNumber(existingTabs: [largest, namedLargest]) == 1)
        #expect(QueryTabManager.nextQueryNumber(existingTabs: [largest, QueryTab(title: "Query 3", tabType: .query)]) == 4)
    }

    // MARK: - Normalizing

    @Test("Line breaks, tabs and separators become one space, and the ends are trimmed")
    func breaksCollapseToOneSpace() {
        #expect(EditorTabNameNormalizer.normalize("  Monthly\n\nreport\t ") == "Monthly report")
        #expect(EditorTabNameNormalizer.normalize("a\u{2028}\u{2029}b") == "a b")
        #expect(EditorTabNameNormalizer.normalize("a\u{0}b") == "a b")
    }

    @Test("A name of only whitespace or invisible format characters is empty")
    func invisibleNameIsEmpty() {
        #expect(EditorTabNameNormalizer.normalize("") == nil)
        #expect(EditorTabNameNormalizer.normalize(" \n\t ") == nil)
        #expect(EditorTabNameNormalizer.normalize("\u{200D}") == nil)
        #expect(EditorTabNameNormalizer.normalize(" \u{FEFF}\u{200B}\u{3000} ") == nil)
    }

    @Test("A joiner inside a name stays, so an emoji keeps its shape")
    func joinerInsideANameStays() {
        let name = "\u{1F469}\u{200D}\u{1F4BB} Report"

        #expect(EditorTabNameNormalizer.normalize(name) == name)
    }

    @Test("A long name is cut at 100 characters as drawn, then trimmed again")
    func longNameIsCutByGraphemes() {
        let spaced = String(repeating: "a", count: 99) + " tail"
        #expect(EditorTabNameNormalizer.normalize(spaced) == String(repeating: "a", count: 99))

        let coder = "\u{1F469}\u{200D}\u{1F4BB}"
        let emoji = EditorTabNameNormalizer.normalize(String(repeating: coder, count: 120))
        #expect(emoji == String(repeating: coder, count: EditorTabNameNormalizer.maximumLength))
    }

    // MARK: - Save As

    @Test("The suggested file name has no path separator and never a doubled extension")
    func suggestedSaveName() {
        #expect(QueryTab.suggestedSaveName(forTitle: "Query 1") == "Query 1.sql")
        #expect(QueryTab.suggestedSaveName(forTitle: "Q3/Q4: totals") == "Q3-Q4- totals.sql")
        #expect(QueryTab.suggestedSaveName(forTitle: "export.sql") == "export.sql")
        #expect(QueryTab.suggestedSaveName(forTitle: "export.SQL") == "export.SQL")
    }

    // MARK: - Restore

    @Test("A restored fixed title reads in the current language, as the window title does")
    func fixedTitlesAreLocalizedAgain() {
        let fixed: [TabType] = [.serverDashboard, .usersRoles, .insights, .tableHealth, .erDiagram, .createTable]
        for tabType in fixed {
            let saved = PersistedTab(id: UUID(), title: "Sơ đồ ER", query: "", tabType: tabType, tableName: nil)
            #expect(QueryTab(from: saved, defaultPageSize: 1_000).title == WindowTitleResolver.title(for: tabType))
        }

        let source = PersistedTab(id: UUID(), title: "Procedure: public.f(date)", query: "", tabType: .objectSource, tableName: nil)
        #expect(QueryTab(from: source, defaultPageSize: 1_000).title == "Procedure: public.f(date)")
    }

    // MARK: - Reopen

    @Test("A reopened tab whose number a new tab took meanwhile takes the next free one")
    func reopenedTabTakesAFreeNumber() {
        let fixture = CoordinatorFixture()
        for _ in 0..<3 {
            fixture.tabManager.addTab()
        }

        fixture.coordinator.adoptRestoredTab(QueryTab(title: "Query 3", query: "SELECT 3", tabType: .query))

        #expect(fixture.tabManager.tabs.map(\.title) == ["Query 1", "Query 2", "Query 3", "Query 4"])
    }

    @Test("A reopened tab the user named Query 3 keeps that name")
    func reopenedNamedTabKeepsItsName() {
        let fixture = CoordinatorFixture()
        for _ in 0..<3 {
            fixture.tabManager.addTab()
        }

        fixture.coordinator.adoptRestoredTab(namedTab("Query 3", automatic: "Query 7", query: "SELECT 3"))

        #expect(fixture.tabManager.tabs.map(\.title) == ["Query 1", "Query 2", "Query 3", "Query 3"])
    }

    // MARK: - Table and schema renames

    private func postgresTableTab(_ name: String, schema: String) -> QueryTab {
        var tab = QueryTab(title: "\(schema).\(name)", query: "SELECT * FROM \(schema).\(name)", tabType: .table, tableName: name)
        tab.tableContext.databaseName = "app"
        tab.tableContext.schemaName = schema
        return tab
    }

    @Test("A table rename keeps the schema in the tab title, as the window title does")
    func tableRenameKeepsTheSchema() throws {
        let fixture = CoordinatorFixture(connection: TestFixtures.makeConnection(type: .postgresql))
        let orders = fixture.addTab(postgresTableTab("orders", schema: "reporting"))

        fixture.coordinator.retitleTabs(ids: [orders.id], to: "orders2")

        #expect(try tab(orders.id, in: fixture.tabManager).title == "reporting.orders2")
    }

    @Test("A schema rename retitles its table tabs and leaves query tab titles alone")
    func schemaRenameRetitlesTableTabsOnly() throws {
        let fixture = CoordinatorFixture(connection: TestFixtures.makeConnection(type: .postgresql))
        let orders = fixture.addTab(postgresTableTab("orders", schema: "reporting"))
        let ranContext = TabTableContext(tableName: "orders", databaseName: "app", schemaName: "reporting")
        var ran = QueryTab(title: "Query 1", query: "SELECT * FROM orders", tabType: .query)
        ran.tableContext = ranContext
        var named = namedTab("Report", automatic: "Query 2", query: "SELECT * FROM orders")
        named.tableContext = ranContext
        fixture.addTab(ran, select: false)
        fixture.addTab(named, select: false)
        let before = fixture.tabManager.tabStructureVersion

        fixture.coordinator.retargetTabs(database: "app", schema: "reporting", toDatabase: "app", toSchema: "analytics")

        #expect(try tab(orders.id, in: fixture.tabManager).title == "analytics.orders")
        #expect(try tab(ran.id, in: fixture.tabManager).title == "Query 1")
        #expect(try tab(named.id, in: fixture.tabManager).title == "Report")
        #expect(fixture.tabManager.tabStructureVersion > before)
    }

    @Test("A schema rename keeps the SQL of a query tab whose last run read a table in it")
    func schemaRenameKeepsQueryTabSQL() throws {
        let fixture = CoordinatorFixture(connection: TestFixtures.makeConnection(type: .postgresql))
        var ran = QueryTab(title: "Query 1", query: "SELECT id FROM orders WHERE total > 10", tabType: .query)
        ran.tableContext = TabTableContext(tableName: "orders", databaseName: "app", schemaName: "reporting")
        fixture.addTab(ran)

        fixture.coordinator.retargetTabs(database: "app", schema: "reporting", toDatabase: "app", toSchema: "analytics")

        let moved = try tab(ran.id, in: fixture.tabManager)
        #expect(moved.content.query == "SELECT id FROM orders WHERE total > 10")
        #expect(moved.tableContext.schemaName == "analytics")
    }
}
