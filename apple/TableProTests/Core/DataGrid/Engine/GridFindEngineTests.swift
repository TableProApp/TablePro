import Foundation
@testable import TablePro
import TableProPluginKit
import Testing

@MainActor
struct GridFindEngineTests {
    private static let people = TableRows.from(
        queryRows: [
            ["active", "Alice", nil],
            ["inactive", "Bob", "note"],
            ["ACTIVE", "Chloé", "act now"]
        ],
        columns: ["status", "name", "remark"],
        columnTypes: [.text(rawType: "TEXT"), .text(rawType: "TEXT"), .text(rawType: "TEXT")]
    )

    private static let status = DataGridColumnID(name: "status", occurrence: 0)
    private static let name = DataGridColumnID(name: "name", occurrence: 0)
    private static let remark = DataGridColumnID(name: "remark", occurrence: 0)

    private func source(
        _ rows: TableRows = people,
        layout: ColumnLayoutState = ColumnLayoutState(),
        order: DataGridRowOrder = .unfiltered,
        formats: [ValueDisplayFormat?] = [],
        revealsInvisibleCharacters: Bool = false
    ) -> GridFindEngine.Source {
        GridFindEngine.Source(
            rows: rows,
            order: order,
            columns: DataGridColumnSet(tableRows: rows, layout: layout),
            displayFormats: formats,
            revealsInvisibleCharacters: revealsInvisibleCharacters
        )
    }

    private func options(
        matchesCase: Bool = false,
        wholeWord: Bool = false,
        regex: Bool = false,
        scope: DataGridColumnID? = nil
    ) -> GridFindState.Options {
        GridFindState.Options(
            matchesCase: matchesCase,
            matchesWholeWord: wholeWord,
            usesRegularExpression: regex,
            columnScope: scope
        )
    }

    private func match(_ row: Int, _ column: DataGridColumnID) -> GridFindState.Match {
        GridFindState.Match(rowID: .existing(row), columnID: column)
    }

    private func search(
        _ term: String,
        _ options: GridFindState.Options = GridFindState.Options(),
        in source: GridFindEngine.Source? = nil
    ) -> GridFindEngine.Result {
        GridFindEngine.search(term, options: options, in: source ?? self.source())
    }

    // MARK: - Matching

    @Test("Matches come in display order, row then displayed column")
    func displayOrder() {
        var layout = ColumnLayoutState()
        layout.columnOrder = ["remark", "status", "name"]

        let result = search("act", in: source(layout: layout))

        #expect(result.matches == [
            match(0, Self.status),
            match(1, Self.status),
            match(2, Self.remark),
            match(2, Self.status)
        ])
        #expect(result.problem == nil)
    }

    @Test("A value filter's order decides the match order and hides filtered rows")
    func followsRowOrder() {
        let order = DataGridRowOrder(filteredIDs: [.existing(2), .existing(0)], revision: 1)

        let result = search("active", in: source(order: order))

        #expect(result.matches == [match(2, Self.status), match(0, Self.status)])
    }

    @Test("Matching ignores case and diacritics unless Match Case is on")
    func caseAndDiacritics() {
        #expect(search("ACTIVE").matches.count == 3)
        #expect(search("chloe").matches == [match(2, Self.name)])
        #expect(search("ACTIVE", options(matchesCase: true)).matches == [match(2, Self.status)])
    }

    @Test("Whole Words skips a term inside a longer word")
    func wholeWords() {
        #expect(search("act", options(wholeWord: true)).matches == [match(2, Self.remark)])
        #expect(search("active", options(wholeWord: true)).matches == [match(0, Self.status), match(2, Self.status)])
    }

    @Test("A regular expression matches by pattern")
    func regularExpression() {
        #expect(search("^b.b$", options(regex: true)).matches == [match(1, Self.name)])
        #expect(search("^in", options(regex: true)).matches == [match(1, Self.status)])
    }

    @Test("An invalid regular expression reports a problem and finds nothing")
    func invalidRegularExpression() {
        let result = search("(", options(regex: true))

        #expect(result.matches.isEmpty)
        #expect(result.problem != nil)
    }

    @Test("A pattern that only matches the empty string finds nothing")
    func emptyRegexMatch() {
        #expect(search("x*", options(regex: true)).matches.isEmpty)
    }

    @Test("An empty or whitespace term finds nothing")
    func emptyTerm() {
        #expect(search("").matches.isEmpty)
        #expect(search("   ").matches.isEmpty)
        #expect(search("", options(regex: true)).matches.isEmpty)
    }

    @Test("A literal term is trimmed")
    func literalTermTrimmed() {
        #expect(search("  bob ").matches == [match(1, Self.name)])
    }

    @Test("A NULL cell is never read")
    func nullNeverRead() {
        let source = self.source()
        let row = Self.people.rows[0]
        let column = source.columns.column(id: Self.remark)

        #expect(column.flatMap { GridFindEngine.searchableText(in: row, column: $0, source: source) } == nil)
    }

    @Test("A column scope searches that column only")
    func columnScope() {
        #expect(search("act", options(scope: Self.remark)).matches == [match(2, Self.remark)])
    }

    @Test("A scope on a column that is not presented searches every column")
    func staleScope() {
        let gone = DataGridColumnID(name: "gone", occurrence: 0)

        #expect(search("act", options(scope: gone)).matches.count == 4)
    }

    @Test("A hidden column is never searched")
    func hiddenColumn() {
        var layout = ColumnLayoutState()
        layout.hiddenColumns = ["status"]

        #expect(search("act", in: source(layout: layout)).matches == [match(2, Self.remark)])
    }

    @Test("A lone carriage return reads as the space the cell shows while marks are off")
    func invisibleCharacters() {
        let rows = TableRows.from(queryRows: [["a\rb"]], columns: ["text"], columnTypes: [.text(rawType: "TEXT")])

        #expect(search("a b", in: source(rows)).matches.count == 1)
        #expect(search("a b", in: source(rows, revealsInvisibleCharacters: true)).matches.isEmpty)
    }

    // MARK: - Binary columns

    private static let payload = TableRows(
        rows: [
            Row(id: .existing(0), values: [.bytes(Data("signup".utf8))]),
            Row(id: .existing(1), values: [.bytes(Data([0x89, 0x50, 0x4E, 0x47]))])
        ],
        columns: ["payload"],
        columnTypes: [.blob(rawType: "VARBINARY(255)")]
    )

    @Test("A binary column showing text is searched on that text")
    func binaryTextColumn() {
        let result = search("signup", in: source(Self.payload, formats: [.text]))

        #expect(result.matches == [match(0, DataGridColumnID(name: "payload", occurrence: 0))])
    }

    @Test("A cell that fell back to hex is not searched on that hex")
    func hexFallbackCell() {
        let source = self.source(Self.payload, formats: [.text])

        #expect(search("8950", in: source).matches.isEmpty)
        #expect(search("0x89504E47", in: source).matches.isEmpty)
    }

    @Test("A binary column left raw is not searched")
    func rawBinaryColumn() {
        let source = self.source(Self.payload)

        #expect(search("signup", in: source).matches.isEmpty)
        #expect(search("8950", in: source).matches.isEmpty)
    }

    // MARK: - Replacing

    private static let contacts = TableRows.from(
        queryRows: [
            ["Foo and FOO", "ann@example.com"],
            ["bar", nil],
            ["food", "bob@example.com"]
        ],
        columns: ["note", "email"],
        columnTypes: [.text(rawType: "TEXT"), .text(rawType: "TEXT")]
    )

    private func replace(
        _ term: String,
        with template: String,
        _ options: GridFindState.Options = GridFindState.Options(),
        writable: (DataGridColumn) -> Bool = { _ in true }
    ) -> GridFindEngine.Replacement {
        let source = self.source(Self.contacts)
        let found = GridFindEngine.search(term, options: options, in: source)
        return GridFindEngine.replacements(
            for: found.matches,
            term: term,
            options: options,
            template: template,
            in: source,
            isWritable: writable
        )
    }

    @Test("Replace writes entered text for every occurrence in a matched cell")
    func replaceLiteral() {
        let result = replace("foo", with: "baz")
        let note = DataGridColumnID(name: "note", occurrence: 0)

        #expect(result.edits == [
            DataGridCellEdit(rowID: .existing(0), columnID: note, value: .enteredText("baz and baz")),
            DataGridCellEdit(rowID: .existing(2), columnID: note, value: .enteredText("bazd"))
        ])
        #expect(result.replacements == 3)
        #expect(result.cells == 2)
    }

    @Test("A literal replacement keeps a dollar sign as typed")
    func literalTemplateIsNotExpanded() {
        let result = replace("bar", with: "$1")

        #expect(result.edits.map { $0.value } == [.enteredText("$1")])
    }

    @Test("A regular expression replacement expands capture groups")
    func regexTemplateExpands() {
        let result = replace("(\\w+)@example\\.com", with: "$1@test.dev", GridFindState.Options(usesRegularExpression: true))

        #expect(result.edits.map { $0.value } == [.enteredText("ann@test.dev"), .enteredText("bob@test.dev")])
    }

    @Test("Replace skips a column it may not write")
    func replaceSkipsUnwritableColumn() {
        let result = replace("example", with: "test") { $0.name != "email" }

        #expect(result.edits.isEmpty)
        #expect(result.replacements == 0)
    }

    @Test("The Replace All message counts matches and cells")
    func replacementMessage() {
        #expect(GridFindEngine.replacementMessage(replacements: 1, cells: 1) == "Replaced 1 match in 1 cell.")
        #expect(GridFindEngine.replacementMessage(replacements: 12, cells: 3) == "Replaced 12 matches in 3 cells.")
        #expect(GridFindEngine.replacementMessage(replacements: 0, cells: 0) == String(localized: "No matches to replace."))
    }

    // MARK: - Stepping

    private let positions: [GridCoord?] = [
        GridCoord(row: 1, displayColumn: 0),
        GridCoord(row: 4, displayColumn: 2),
        GridCoord(row: 4, displayColumn: 5),
        GridCoord(row: 9, displayColumn: 0)
    ]

    @Test("A new search lands on the first match at or after the cursor, else the first")
    func landingIndex() {
        #expect(GridFindEngine.index(atOrAfter: nil, in: positions) == 0)
        #expect(GridFindEngine.index(atOrAfter: GridCoord(row: 4, displayColumn: 2), in: positions) == 1)
        #expect(GridFindEngine.index(atOrAfter: GridCoord(row: 4, displayColumn: 3), in: positions) == 2)
        #expect(GridFindEngine.index(atOrAfter: GridCoord(row: 10, displayColumn: 0), in: positions) == 0)
        #expect(GridFindEngine.index(atOrAfter: nil, in: []) == nil)
    }

    @Test("Stepping from the current match wraps both ways")
    func stepWraps() {
        #expect(GridFindEngine.step(from: nil, active: nil, positions: positions, forward: true) == 0)
        #expect(GridFindEngine.step(from: nil, active: nil, positions: positions, forward: false) == 3)
        #expect(GridFindEngine.step(from: 3, active: positions[3], positions: positions, forward: true) == 0)
        #expect(GridFindEngine.step(from: 0, active: positions[0], positions: positions, forward: false) == 3)
        #expect(GridFindEngine.step(from: 1, active: positions[1], positions: positions, forward: true) == 2)
        #expect(GridFindEngine.step(from: nil, active: nil, positions: [], forward: true) == nil)
    }

    @Test("Once the cursor leaves the current match, stepping starts from the cursor")
    func stepFromCursor() {
        let cursor = GridCoord(row: 5, displayColumn: 0)

        #expect(GridFindEngine.step(from: 0, active: cursor, positions: positions, forward: true) == 3)
        #expect(GridFindEngine.step(from: 0, active: cursor, positions: positions, forward: false) == 2)
        #expect(GridFindEngine.step(from: 3, active: GridCoord(row: 20, displayColumn: 0), positions: positions, forward: true) == 0)
    }
}

// MARK: - Model

@MainActor
private final class FindGridOwner: DataGridDataSource, DataGridActions {
    var tableRows: TableRows
    let changeState: AnyChangeManager
    private(set) var commits: [(edits: [DataGridResolvedEdit], actionName: String)] = []
    private(set) var searchedTerms: [String] = []

    init(_ tableRows: TableRows) {
        self.tableRows = tableRows
        self.changeState = AnyChangeManager(DataChangeManager())
    }

    var gridRows: TableRows { tableRows }
    var gridChangeState: AnyChangeManager { changeState }
    var hasUnloadedRows = false
    var gridHasUnloadedRows: Bool { hasUnloadedRows }

    func gridCommit(_ edits: [DataGridResolvedEdit], actionName: String) -> Bool {
        commits.append((edits, actionName))
        for edit in edits {
            guard let index = tableRows.index(of: edit.rowID) else { continue }
            tableRows.rows[index].values[edit.dataIndex] = edit.newValue
        }
        return true
    }

    func gridSearchAllRows(term: String) {
        searchedTerms.append(term)
    }
}

@MainActor
struct DataGridModelFindTests {
    private static let companies = TableRows.from(
        queryRows: [
            ["1", "Globex", "St. Louis"],
            ["2", "Initech", "Acme Falls"],
            ["3", "Acme", "Paris"],
            ["4", "Acme Corp", "Acme"]
        ],
        columns: ["id", "company", "city"],
        columnTypes: [.integer(rawType: "INT"), .text(rawType: "TEXT"), .text(rawType: "TEXT")]
    )

    private static let company = DataGridColumnID(name: "company", occurrence: 0)

    private func mount(
        _ configure: (inout DataGridConfiguration) -> Void = { _ in }
    ) -> (DataGridModel, FindGridOwner) {
        var configuration = DataGridConfiguration()
        configure(&configuration)
        let owner = FindGridOwner(Self.companies)
        let model = DataGridModel(configuration: configuration)
        model.dataSource = owner
        model.actions = owner
        model.reloadRows()
        return (model, owner)
    }

    private func cell(_ row: Int, _ column: Int) -> GridSelection {
        GridSelectionReducer.single(GridCoord(row: row, displayColumn: column))
    }

    private func search(_ model: DataGridModel, _ term: String) {
        model.showFind()
        model.find.term = term
        model.findQueryDidChange()
    }

    @Test("A match becomes the active cell, column included")
    func matchSetsActiveCell() {
        let (model, owner) = mount()
        model.setSelection(cell(2, 0))

        search(model, "acme")

        #expect(model.find.matches.count == 4)
        #expect(model.find.currentIndex == 1)
        #expect(model.selection.activeCell == GridCoord(row: 2, displayColumn: 1))
        #expect(model.activeCell?.column.name == "company")
        #expect(owner.commits.isEmpty)
    }

    @Test("Find Next walks the matches and wraps")
    func findNextWraps() {
        let (model, owner) = mount()
        search(model, "acme")
        #expect(model.selection.activeCell == GridCoord(row: 1, displayColumn: 2))

        model.findNext()
        #expect(model.selection.activeCell == GridCoord(row: 2, displayColumn: 1))
        model.findNext()
        model.findNext()
        #expect(model.selection.activeCell == GridCoord(row: 3, displayColumn: 2))
        model.findNext()
        #expect(model.selection.activeCell == GridCoord(row: 1, displayColumn: 2))
        #expect(model.find.currentIndex == 0)
        #expect(owner.commits.isEmpty)
    }

    @Test("Find Previous starts from where the user moved the cursor")
    func findPreviousFromCursor() {
        let (model, owner) = mount()
        search(model, "acme")
        model.setSelection(cell(3, 0))

        model.findPrevious()

        #expect(model.selection.activeCell == GridCoord(row: 2, displayColumn: 1))
        #expect(owner.commits.isEmpty)
    }

    @Test("A refresh keeps the current match by identity and leaves the selection alone")
    func refreshKeepsCurrentMatch() {
        let (model, owner) = mount()
        model.setSelection(cell(2, 0))
        search(model, "acme")

        owner.tableRows.rows[0].values[2] = .text("Acme Town")
        model.reloadRows()
        model.refreshFind()

        #expect(model.find.matches.count == 5)
        #expect(model.find.currentMatch == GridFindState.Match(rowID: .existing(2), columnID: Self.company))
        #expect(model.find.currentIndex == 2)
        #expect(model.selection.activeCell == GridCoord(row: 2, displayColumn: 1))
    }

    @Test("Replace commits the current match as one edit and moves to the next match")
    func replaceCurrent() {
        let (model, owner) = mount { $0.isEditable = true }
        search(model, "acme")
        model.find.replacement = "Umbrella"

        model.replaceCurrentMatch()

        #expect(owner.commits.count == 1)
        #expect(owner.commits.first?.actionName == String(localized: "Replace"))
        #expect(owner.commits.first?.edits.map { $0.newValue } == [.text("Umbrella Falls")])
        #expect(owner.commits.first?.edits.map { $0.rowID } == [.existing(1)])
        #expect(model.find.matches.count == 3)
        #expect(model.selection.activeCell == GridCoord(row: 2, displayColumn: 1))
    }

    @Test("Replace All is one commit and leaves a column it may not write")
    func replaceAllOneCommit() throws {
        let (model, owner) = mount {
            $0.isEditable = true
            $0.lockedColumns = ["city"]
        }
        search(model, "acme")
        model.find.replacement = "Umbrella"

        let outcome = try #require(model.replaceAllMatches())

        #expect(outcome.cells == 2)
        #expect(outcome.replacements == 2)
        #expect(owner.commits.count == 1)
        #expect(owner.commits.first?.actionName == String(localized: "Replace All"))
        #expect(owner.commits.first?.edits.map { $0.newValue } == [.text("Umbrella"), .text("Umbrella Corp")])
        #expect(model.find.matches.count == 2)
    }

    @Test("A read-only grid offers no replace")
    func readOnlyGridHasNoReplace() {
        let (model, owner) = mount()
        model.showFind(replace: true)
        model.find.term = "acme"
        model.findQueryDidChange()

        #expect(model.find.showsReplace == false)
        #expect(model.replaceAllMatches() == nil)
        model.replaceCurrentMatch()
        #expect(owner.commits.isEmpty)
    }

    @Test("Hiding the bar clears the term, the matches, the scope and the replace row")
    func hideClears() {
        let (model, owner) = mount { $0.isEditable = true }
        model.findInColumn(Self.company, replace: true)
        model.find.term = "acme"
        model.findQueryDidChange()
        #expect(model.find.matches.count == 2)

        model.hideFind()

        #expect(model.find.isVisible == false)
        #expect(model.find.term.isEmpty)
        #expect(model.find.matches.isEmpty)
        #expect(model.find.options.columnScope == nil)
        #expect(model.find.showsReplace == false)
        #expect(owner.commits.isEmpty)
    }

    @Test("Search All Rows hands the trimmed term to the owner only where the grid offers it")
    func searchAllRows() {
        let (plain, plainOwner) = mount()
        search(plain, "  zzz ")
        plain.searchAllRows()
        #expect(plainOwner.searchedTerms.isEmpty)
        #expect(plain.find.isVisible)

        let (offered, owner) = mount { $0.commands = [.searchAllRows] }
        search(offered, "  zzz ")
        offered.searchAllRows()
        #expect(owner.searchedTerms == ["zzz"])
        #expect(offered.find.isVisible == false)
    }

    @Test("The counter names the page whenever the owner holds more rows, Search All Rows offered or not")
    func pageScopeFollowsTheOwnersRows() {
        let (model, owner) = mount()
        #expect(!model.findCoversPageOnly)

        owner.hasUnloadedRows = true
        #expect(model.findCoversPageOnly)
        #expect(!model.offersSearchAllRows)
    }

    @Test("Use Selection for Find takes the cell's text, escaped for a regular expression")
    func useSelectionForFind() {
        let (model, owner) = mount()
        model.setSelection(cell(0, 2))
        model.find.options.usesRegularExpression = true

        model.useSelectionForFind()

        #expect(model.find.isVisible)
        #expect(model.find.term == NSRegularExpression.escapedPattern(for: "St. Louis"))
        #expect(model.find.matches == [GridFindState.Match(rowID: .existing(0), columnID: DataGridColumnID(name: "city", occurrence: 0))])
        #expect(owner.commits.isEmpty)
    }
}
