import Foundation
@testable import TablePro
import TableProPluginKit
import TableProTabular
import TableProTabularIO
import TableProTestSupport
import Testing

// Holds ten rows and shows four at a time, as a data file shows a page of its rows.
@MainActor
private final class PagedFindOwner: DataGridDataSource, DataGridActions, DataGridDatasetFinding {
    static let columns = ["name", "city"]

    private(set) var values: [[String]]
    let pageSize: Int
    weak var model: DataGridModel?
    var gate: AsyncGate?
    private(set) var pageOffset = 0
    private(set) var page = TableRows()
    private(set) var searches: [GridDatasetFindQuery] = []
    private(set) var replaceAllQueries: [GridDatasetFindQuery] = []
    private(set) var ownerCommits = 0
    private(set) var gridCommits = 0
    private let changeState = AnyChangeManager(DataFileChangeManager())

    init(_ values: [[String]], pageSize: Int) {
        self.values = values
        self.pageSize = pageSize
        rebuildPage()
    }

    var gridRows: TableRows { page }
    var gridChangeState: AnyChangeManager { changeState }
    var gridRowNumberOffset: Int { pageOffset }

    func gridCommit(_ edits: [DataGridResolvedEdit], actionName: String) -> Bool {
        gridCommits += 1
        return true
    }

    func gridFindAll(_ query: GridDatasetFindQuery) async throws -> [GridFindState.Match] {
        searches.append(query)
        if let gate {
            await gate.wait()
        }
        return matches(for: query)
    }

    func gridDisplayPosition(of rowID: RowID) -> Int? {
        guard case .existing(let index) = rowID, values.indices.contains(index) else { return nil }
        return index
    }

    func gridLoadRow(_ rowID: RowID) -> Bool {
        guard let position = gridDisplayPosition(of: rowID) else { return false }
        let offset = (position / pageSize) * pageSize
        if offset != pageOffset {
            pageOffset = offset
            reload()
        }
        return true
    }

    func gridReplace(_ match: GridFindState.Match, query: GridDatasetFindQuery, with template: String) -> Bool {
        guard case .existing(let index) = match.rowID, let column = dataIndex(of: match.columnID) else { return false }
        let original = values[index][column]
        let replaced = original.replacingOccurrences(of: query.term, with: template, options: .caseInsensitive)
        guard replaced != original else { return false }
        values[index][column] = replaced
        ownerCommits += 1
        datasetDidChange()
        return true
    }

    func gridReplaceAll(_ query: GridDatasetFindQuery, with template: String) {
        replaceAllQueries.append(query)
        for match in matches(for: query) {
            guard case .existing(let index) = match.rowID, let column = dataIndex(of: match.columnID) else { continue }
            values[index][column] = values[index][column]
                .replacingOccurrences(of: query.term, with: template, options: .caseInsensitive)
        }
        ownerCommits += 1
        datasetDidChange()
    }

    // An edit the grid did not make, such as an undo.
    func edit(row: Int, column: Int, to text: String) {
        values[row][column] = text
        datasetDidChange()
    }

    private func matches(for query: GridDatasetFindQuery) -> [GridFindState.Match] {
        var found: [GridFindState.Match] = []
        for (index, row) in values.enumerated() {
            for column in query.columns {
                guard let dataIndex = dataIndex(of: column),
                      row[dataIndex].localizedCaseInsensitiveContains(query.term) else { continue }
                found.append(GridFindState.Match(rowID: .existing(index), columnID: column))
            }
        }
        return found
    }

    private func dataIndex(of column: DataGridColumnID) -> Int? {
        DataGridColumnSet.columnIDs(for: Self.columns).firstIndex(of: column)
    }

    private func datasetDidChange() {
        reload()
        model?.findDatasetDidChange()
    }

    private func reload() {
        rebuildPage()
        model?.reloadRows()
    }

    private func rebuildPage() {
        var rows = ContiguousArray<Row>()
        for index in pageOffset..<min(pageOffset + pageSize, values.count) {
            rows.append(Row(id: .existing(index), values: ContiguousArray(values[index].map { PluginCellValue.text($0) })))
        }
        page = TableRows(
            rows: rows,
            columns: Self.columns,
            columnTypes: Self.columns.map { _ in ColumnType.text(rawType: "TEXT") }
        )
    }
}

@MainActor
struct GridDatasetFindTests {
    private static let rows = [
        ["ann", "Paris"], ["bob", "Lyon"], ["cid", "Paris"], ["dan", "Nice"],
        ["eve", "Rome"], ["fay", "Paris"], ["gus", "Oslo"], ["hal", "Bern"],
        ["ivy", "Paris"], ["jon", "Lima"],
    ]

    private static let name = DataGridColumnID(name: "name", occurrence: 0)
    private static let city = DataGridColumnID(name: "city", occurrence: 0)

    private func mount(editable: Bool = false, commands: Set<DataGridCommand> = []) -> (DataGridModel, PagedFindOwner) {
        var configuration = DataGridConfiguration()
        configuration.isEditable = editable
        configuration.commands = commands
        let owner = PagedFindOwner(Self.rows, pageSize: 4)
        let model = DataGridModel(configuration: configuration)
        model.dataSource = owner
        model.actions = owner
        model.datasetFinder = owner
        owner.model = model
        model.reloadRows()
        return (model, owner)
    }

    private func search(_ model: DataGridModel, _ term: String, replacement: String? = nil) async {
        model.showFind(replace: replacement != nil)
        model.find.term = term
        if let replacement {
            model.find.replacement = replacement
        }
        model.findQueryDidChange()
        await model.findSearchSettled()
    }

    private func match(_ row: Int) -> GridFindState.Match {
        GridFindState.Match(rowID: .existing(row), columnID: Self.city)
    }

    // A find match selects its row with the cursor on the matched cell, as a click does.
    private func cell(_ row: Int, _ column: Int, in model: DataGridModel) -> GridSelection {
        GridSelectionReducer.cursor(
            GridCoord(row: row, displayColumn: column),
            in: GridSelectionContext(rowCount: model.rowCount, columnCount: model.columns.count)
        )
    }

    @Test("The count covers every row the owner holds, not the loaded page")
    func countCoversEveryRow() async {
        let (model, owner) = mount(commands: [.searchAllRows])

        await search(model, "paris")

        #expect(model.find.matches == [match(0), match(2), match(5), match(8)])
        #expect(model.find.currentIndex == 0)
        #expect(model.find.isSearching == false)
        #expect(owner.searches.map { $0.columns } == [[Self.name, Self.city]])
        #expect(model.offersSearchAllRows == false)
    }

    @Test("Find Next across a page boundary loads that page and selects the cell")
    func findNextCrossesPage() async {
        let (model, owner) = mount()
        await search(model, "paris")
        #expect(model.selection == cell(0, 1, in: model))

        model.findNext()
        #expect(owner.pageOffset == 0)
        #expect(model.selection == cell(2, 1, in: model))

        model.findNext()
        #expect(owner.pageOffset == 4)
        #expect(model.selection == cell(1, 1, in: model))
        #expect(model.activeCell?.rowID == .existing(5))
        #expect(model.find.currentIndex == 2)

        model.findNext()
        model.findNext()
        #expect(owner.pageOffset == 0)
        #expect(model.selection == cell(0, 1, in: model))
        #expect(model.find.currentIndex == 0)
        #expect(owner.searches.count == 1)
    }

    @Test("Find Previous from the first match wraps to the last page")
    func findPreviousWraps() async {
        let (model, owner) = mount()
        await search(model, "paris")

        model.findPrevious()

        #expect(owner.pageOffset == 8)
        #expect(model.activeCell?.rowID == .existing(8))
        #expect(model.find.currentIndex == 3)
    }

    @Test("Find Next starts from where the user moved the cursor")
    func findNextFromCursor() async {
        let (model, owner) = mount()
        await search(model, "paris")
        model.setSelection(cell(3, 0, in: model))

        model.findNext()

        #expect(owner.pageOffset == 4)
        #expect(model.activeCell?.rowID == .existing(5))
        #expect(model.find.currentIndex == 2)
    }

    @Test("A new search lands on the first match from the cursor, on the page that holds it")
    func searchStartsFromCursor() async {
        let (model, owner) = mount()
        let loaded = owner.gridLoadRow(.existing(6))
        #expect(loaded)
        model.setSelection(cell(2, 0, in: model))

        await search(model, "paris")

        #expect(model.find.currentIndex == 3)
        #expect(owner.pageOffset == 8)
        #expect(model.selection == cell(0, 1, in: model))
    }

    @Test("A change in the owner's rows searches again and keeps the current match")
    func datasetChangeKeepsCurrentMatch() async {
        let (model, owner) = mount()
        await search(model, "paris")
        model.findNext()
        #expect(model.find.currentMatch == match(2))

        owner.edit(row: 1, column: 1, to: "Paris")
        await model.findSearchSettled()

        #expect(owner.searches.count == 2)
        #expect(model.find.matches == [match(0), match(1), match(2), match(5), match(8)])
        #expect(model.find.currentMatch == match(2))
    }

    @Test("Replace writes through the owner and moves to the next match on its page")
    func replaceMovesToNextMatch() async {
        let (model, owner) = mount(editable: true)
        await search(model, "paris", replacement: "Turin")
        model.findNext()

        model.replaceCurrentMatch()

        #expect(owner.values[2][1] == "Turin")
        #expect(owner.ownerCommits == 1)
        #expect(owner.gridCommits == 0)
        #expect(model.find.currentMatch == match(5))
        #expect(owner.pageOffset == 4)
        #expect(model.selection == cell(1, 1, in: model))

        await model.findSearchSettled()
        #expect(model.find.matches == [match(0), match(5), match(8)])
        #expect(model.find.currentMatch == match(5))
    }

    @Test("Replace All hands the owner one query and lands as one commit")
    func replaceAllIsOneCommit() async {
        let (model, owner) = mount(editable: true)
        await search(model, "paris", replacement: "Turin")

        let outcome = model.replaceAllMatches()

        #expect(outcome == nil)
        #expect(owner.replaceAllQueries.map { $0.term } == ["paris"])
        #expect(owner.replaceAllQueries.map { $0.columns } == [[Self.name, Self.city]])
        #expect(owner.ownerCommits == 1)
        #expect(owner.gridCommits == 0)
        #expect(owner.values.filter { $0[1] == "Turin" }.count == 4)

        await model.findSearchSettled()
        #expect(model.find.matches.isEmpty)
        #expect(owner.searches.count == 2)
    }

    @Test("An invalid regular expression reports a problem without asking the owner")
    func invalidPatternSkipsOwner() async {
        let (model, owner) = mount()
        model.showFind()
        model.find.options.usesRegularExpression = true
        model.find.term = "(paris"

        model.findQueryDidChange()
        await model.findSearchSettled()

        #expect(model.find.problem == GridFindEngine.invalidPatternProblem)
        #expect(owner.searches.isEmpty)
    }

    @Test("Stopping a search clears its progress and drops the result it returns late")
    func stopDropsLateResult() async throws {
        let (model, owner) = mount()
        let gate = AsyncGate()
        owner.gate = gate
        model.showFind()
        model.find.term = "paris"
        model.findQueryDidChange()
        let running = try #require(model.find.datasetSearch)
        await gate.arrived(1)
        #expect(model.find.isSearching)

        model.stopFindSearch()
        #expect(model.find.isSearching == false)
        #expect(model.find.searchStopped)

        await gate.open()
        await running.value
        #expect(model.find.matches.isEmpty)
        #expect(model.find.datasetSearch == nil)
    }

    @Test("Bisection finds the match at, after and before a cell and wraps at the ends")
    func sortedIndexWraps() {
        let cells = [
            GridCoord(row: 0, displayColumn: 1),
            GridCoord(row: 2, displayColumn: 0),
            GridCoord(row: 2, displayColumn: 3),
            GridCoord(row: 7, displayColumn: 1),
        ]
        let position = { (index: Int) -> GridCoord? in cells[index] }
        let middle = GridCoord(row: 2, displayColumn: 0)

        #expect(GridFindEngine.sortedIndex(atOrAfter: middle, count: 4, position: position) == 1)
        #expect(GridFindEngine.sortedIndex(after: middle, count: 4, position: position) == 2)
        #expect(GridFindEngine.sortedIndex(before: middle, count: 4, position: position) == 0)
        #expect(GridFindEngine.sortedIndex(atOrAfter: GridCoord(row: 8, displayColumn: 0), count: 4, position: position) == 0)
        #expect(GridFindEngine.sortedIndex(after: cells[3], count: 4, position: position) == 0)
        #expect(GridFindEngine.sortedIndex(before: cells[0], count: 4, position: position) == 3)
        #expect(GridFindEngine.sortedIndex(after: middle, count: 0, position: position) == nil)
    }
}

@MainActor
struct DataFileWholeFileFindTests {
    private static let file = "name,n\nfoo,1\nbar,2\nfoo,3\nbaz,4\nfoo,5\n"

    private let undoManager = UndoManager()

    private func loaded(pageSize: Int) async throws -> DataFileController {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("GridDatasetFindTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("rows.csv")
        try Data(Self.file.utf8).write(to: url)
        let controller = DataFileController()
        controller.undoManager = undoManager
        let kind = try #require(DataFileKind.classify(url))
        controller.load(url: url, kind: kind)
        await controller.waitForPendingWork()
        #expect(controller.loadState == .loaded)
        controller.pageSize = pageSize
        controller.refreshPage()
        controller.gridModel.configuration.isEditable = controller.isEditable
        return controller
    }

    private func search(_ controller: DataFileController, replacement: String? = nil) async {
        let model = controller.gridModel
        model.showFind(replace: replacement != nil)
        model.find.term = "foo"
        if let replacement {
            model.find.replacement = replacement
        }
        model.findQueryDidChange()
        await controller.waitForPendingWork()
    }

    private func names(_ controller: DataFileController) -> [String] {
        guard let table = controller.table else { return [] }
        return (0..<table.rowCount).map { table.cells(row: $0).first?.text ?? "" }
    }

    @Test("Find counts matches on every page and Find Next loads the page that holds the next one")
    func findCoversEveryPage() async throws {
        let controller = try await loaded(pageSize: 2)
        let model = controller.gridModel

        await search(controller)

        #expect(model.find.matches.count == 3)
        #expect(controller.pageOffset == 0)
        model.findNext()
        #expect(controller.pageOffset == 2)
        #expect(model.selection.activeCell == GridCoord(row: 0, displayColumn: 0))
        model.findNext()
        #expect(controller.pageOffset == 4)
    }

    @Test("Replace changes one cell and moves to the next match on another page")
    func replaceMovesToNextPage() async throws {
        let controller = try await loaded(pageSize: 2)
        let model = controller.gridModel
        await search(controller, replacement: "qux")

        model.replaceCurrentMatch()

        #expect(names(controller) == ["qux", "bar", "foo", "baz", "foo"])
        #expect(controller.pageOffset == 2)
        await controller.waitForPendingWork()
        #expect(model.find.matches.count == 2)
    }

    @Test("Replace All covers every page as one undo step, and Undo finds the matches again")
    func replaceAllIsOneUndoStep() async throws {
        let controller = try await loaded(pageSize: 2)
        let model = controller.gridModel
        await search(controller, replacement: "qux")

        model.replaceAllMatches()
        await controller.waitForPendingWork()

        #expect(names(controller) == ["qux", "bar", "qux", "baz", "qux"])
        #expect(controller.statusMessage == GridFindEngine.replacementMessage(replacements: 3, cells: 3))
        #expect(model.find.matches.isEmpty)

        controller.undoManager?.undo()
        await controller.waitForPendingWork()
        #expect(names(controller) == ["foo", "bar", "foo", "baz", "foo"])
        #expect(model.find.matches.count == 3)
    }

    @Test("Cancel stops a running find")
    func cancelStopsFind() async throws {
        let controller = try await loaded(pageSize: 2)
        let model = controller.gridModel
        model.showFind()
        model.find.term = "foo"
        model.findQueryDidChange()
        let running = try #require(model.find.datasetSearch)

        controller.cancelActivity()

        #expect(running.isCancelled)
        #expect(model.find.isSearching == false)
        await controller.waitForPendingWork()
    }
}
