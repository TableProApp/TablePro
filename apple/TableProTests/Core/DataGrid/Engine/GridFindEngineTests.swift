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

    // MARK: - Refreshing

    @Test("Reading only the written cells and the added rows again finds what a full search finds")
    func refreshMatchesAFullSearch() throws {
        var rows = Self.people
        let before = search("act", in: source(rows)).matches
        rows.edit(row: 1, column: 2, value: .text("acting"))
        rows.edit(row: 2, column: 0, value: .text("done"))
        rows.appendInsertedRow(values: [.text("react"), .text("Dee"), .null])
        let inserted = try #require(rows.rows.last?.id)
        rows.remove(at: IndexSet(integer: 0))

        let refreshed = GridFindEngine.refreshed(
            before,
            writtenCells: [.existing(1): IndexSet(integer: 2), .existing(2): IndexSet(integer: 0)],
            addedRows: [inserted],
            term: "act",
            options: GridFindState.Options(),
            in: source(rows)
        )

        let expected = [
            match(1, Self.status),
            match(1, Self.remark),
            match(2, Self.remark),
            GridFindState.Match(rowID: inserted, columnID: Self.status)
        ]
        #expect(refreshed?.matches == expected)
        #expect(search("act", in: source(rows)).matches == expected)
    }

    @Test("Under a value filter a refresh keeps the filter's order and leaves out a hidden row it rereads")
    func refreshFollowsTheFilteredOrder() {
        let order = DataGridRowOrder(filteredIDs: [.existing(2), .existing(0)], revision: 1)
        var rows = Self.people
        let before = search("act", in: source(rows, order: order)).matches
        rows.edit(row: 0, column: 2, value: .text("react"))
        rows.edit(row: 1, column: 1, value: .text("Actor"))

        let refreshed = GridFindEngine.refreshed(
            before,
            writtenCells: [.existing(0): IndexSet(integer: 2), .existing(1): IndexSet(integer: 1)],
            addedRows: [],
            term: "act",
            options: GridFindState.Options(),
            in: source(rows, order: order)
        )

        #expect(refreshed?.matches == search("act", in: source(rows, order: order)).matches)
        #expect(refreshed?.matches == [match(2, Self.status), match(2, Self.remark), match(0, Self.status), match(0, Self.remark)])
    }

    @Test("A term that cannot match leaves the refresh to a full search")
    func refreshWithoutATerm() {
        let blank = GridFindEngine.refreshed(
            [], writtenCells: [:], addedRows: [.existing(0)], term: " ", options: GridFindState.Options(), in: source()
        )
        let invalid = GridFindEngine.refreshed(
            [], writtenCells: [:], addedRows: [], term: "(", options: options(regex: true), in: source()
        )

        #expect(blank == nil)
        #expect(invalid == nil)
    }

    // The cost pin: the caller names the written cells, and every other cell keeps its match without being read.
    @Test("Only the written cells of a row are read again")
    func refreshReadsOnlyTheWrittenCells() {
        var rows = Self.people
        let before = search("act", in: source(rows)).matches
        rows.edit(row: 2, column: 0, value: .text("done"))
        rows.edit(row: 2, column: 1, value: .text("Actor"))

        let refreshed = GridFindEngine.refreshed(
            before,
            writtenCells: [.existing(2): IndexSet(integer: 1)],
            addedRows: [],
            term: "act",
            options: GridFindState.Options(),
            in: source(rows)
        )

        #expect(refreshed?.matches == [
            match(0, Self.status),
            match(1, Self.status),
            match(2, Self.status),
            match(2, Self.name),
            match(2, Self.remark)
        ])
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

    // MARK: - Off the main actor

    private static let shownValues = TableRows(
        rows: [
            Row(id: .existing(0), values: [
                .text("2024-03-15 09:30:00.123456"),
                .text("2024-12-31 23:59:59+07"),
                .text("2024-03-15"),
                .bytes(Data("signup".utf8)),
                .bytes(Data((0..<16).map { UInt8($0) })),
                .text("1700000000"),
                .text("1700000000000"),
                .text("a\rb")
            ]),
            Row(id: .existing(1), values: [
                .text("2023-11-14 22:13:20"),
                .null,
                .text("1999-01-01"),
                .bytes(Data([0x89, 0x50, 0x4E, 0x47])),
                .bytes(Data(repeating: 0xAB, count: 16)),
                .text("1700003600"),
                .text("1700003600000"),
                .text("plain")
            ])
        ],
        columns: ["created", "updated", "born", "payload", "token", "stamp", "stampMillis", "note"],
        columnTypes: [
            .datetime(rawType: "DATETIME(6)"),
            .timestamp(rawType: "TIMESTAMPTZ"),
            .date(rawType: "DATE"),
            .blob(rawType: "VARBINARY(255)"),
            .blob(rawType: "BINARY(16)"),
            .integer(rawType: "BIGINT"),
            .integer(rawType: "BIGINT"),
            .text(rawType: "TEXT")
        ]
    )

    private static let shownFormats: [ValueDisplayFormat?] = [nil, nil, nil, .text, .uuid, .unixTimestamp, .unixTimestampMillis, nil]

    private static let shownTerms = [
        "2024", "2023", "09:30:00.123456", "+07", "/", "PM", "signup", "00010203-0405", "abab", "a b", "b", "11"
    ]

    // Both sides use the same renderer code, so this pins the same cells on and off the main actor, not the shown text.
    @Test("The same search finds the same cells on and off the main actor, under every date format")
    func searchOffTheMainActorMatchesTheMainActor() async {
        for revealsInvisibleCharacters in [false, true] {
            let source = self.source(Self.shownValues, formats: Self.shownFormats, revealsInvisibleCharacters: revealsInvisibleCharacters)
            for format in DateFormatOption.allCases {
                for term in Self.shownTerms {
                    let onMain = GridFindEngine.search(
                        term,
                        options: GridFindState.Options(),
                        in: source,
                        dates: DateDisplayRenderer(format: format),
                        isCancelled: { false }
                    )
                    let offMain = await GridFindEngine.searchOffTheMainActor(
                        term,
                        options: GridFindState.Options(),
                        in: source,
                        dateFormat: format
                    )
                    #expect(offMain == onMain, "same cells on and off the main actor: \(format) \(term) reveals: \(revealsInvisibleCharacters)")
                }
            }
            for term in Self.shownTerms {
                let shared = await GridFindEngine.searchOffTheMainActor(
                    term,
                    options: GridFindState.Options(),
                    in: source,
                    dateFormat: DateFormattingService.shared.currentFormat
                )
                #expect(shared == search(term, in: source), "\(term)")
            }
        }
    }

    @Test("The off-main search renders dates, bytes and timestamps the way the cells show them")
    func searchOffTheMainActorReadsTheShownText() async {
        let source = self.source(Self.shownValues, formats: Self.shownFormats)
        func column(_ name: String) -> DataGridColumnID { DataGridColumnID(name: name, occurrence: 0) }
        func found(_ term: String, _ format: DateFormatOption = .iso8601) async -> [GridFindState.Match]? {
            await GridFindEngine.searchOffTheMainActor(term, options: GridFindState.Options(), in: source, dateFormat: format)?.matches
        }

        #expect(await found("15/03/2024", .euLong) == [match(0, column("created")), match(0, column("born"))])
        #expect(await found("09:30:00.123456 AM", .usLong) == [match(0, column("created"))])
        #expect(await found("23:59:59+07") == [match(0, column("updated"))])
        #expect(await found("signup") == [match(0, column("payload"))])
        #expect(await found("00010203-0405-0607-0809-0a0b0c0d0e0f") == [match(0, column("token"))])
        #expect(await found("a b") == [match(0, column("note"))])
        #expect(await found("8950")?.isEmpty == true)
    }

    @Test("A search asks whether to stop every 4,096 cells and gives up when told to")
    func searchChecksForCancellation() {
        let rows = TableRows.from(
            queryRows: (0..<10_000).map { [PluginCellValue.text("row \($0)")] },
            columns: ["v"],
            columnTypes: [.text(rawType: "TEXT")]
        )
        let dates = DateDisplayRenderer(format: .iso8601)
        var checks = 0

        let finished = GridFindEngine.search("row", options: GridFindState.Options(), in: source(rows), dates: dates) {
            checks += 1
            return false
        }
        let stopped = GridFindEngine.search(
            "row", options: GridFindState.Options(), in: source(rows), dates: dates, isCancelled: { true }
        )

        #expect(finished?.matches.count == 10_000)
        #expect(checks == 3)
        #expect(stopped == nil)
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
    private static let city = DataGridColumnID(name: "city", occurrence: 0)

    private func match(_ row: Int, _ column: DataGridColumnID) -> GridFindState.Match {
        GridFindState.Match(rowID: .existing(row), columnID: column)
    }

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

    private func search(_ model: DataGridModel, _ term: String) async {
        model.showFind()
        model.find.term = term
        model.findQueryDidChange()
        await model.findSearchSettled()
    }

    @Test("A match becomes the active cell, column included")
    func matchSetsActiveCell() async {
        let (model, owner) = mount()
        model.setSelection(cell(2, 0))

        await search(model, "acme")

        #expect(model.find.matches.count == 4)
        #expect(model.find.currentIndex == 1)
        #expect(model.selection.activeCell == GridCoord(row: 2, displayColumn: 1))
        #expect(model.activeCell?.column.name == "company")
        #expect(owner.commits.isEmpty)
    }

    @Test("Find Next walks the matches and wraps")
    func findNextWraps() async {
        let (model, owner) = mount()
        await search(model, "acme")
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
    func findPreviousFromCursor() async {
        let (model, owner) = mount()
        await search(model, "acme")
        model.setSelection(cell(3, 0))

        model.findPrevious()

        #expect(model.selection.activeCell == GridCoord(row: 2, displayColumn: 1))
        #expect(owner.commits.isEmpty)
    }

    @Test("A refresh keeps the current match by identity and leaves the selection alone")
    func refreshKeepsCurrentMatch() async {
        let (model, owner) = mount()
        model.setSelection(cell(2, 0))
        await search(model, "acme")

        owner.tableRows.rows[0].values[2] = .text("Acme Town")
        model.reloadRows()
        model.refreshFind()
        await model.findSearchSettled()

        #expect(model.find.matches.count == 5)
        #expect(model.find.currentMatch == GridFindState.Match(rowID: .existing(2), columnID: Self.company))
        #expect(model.find.currentIndex == 2)
        #expect(model.selection.activeCell == GridCoord(row: 2, displayColumn: 1))
    }

    @Test("Replace commits the current match as one edit and moves to the next match")
    func replaceCurrent() async {
        let (model, owner) = mount { $0.isEditable = true }
        await search(model, "acme")
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
    func replaceAllOneCommit() async throws {
        let (model, owner) = mount {
            $0.isEditable = true
            $0.lockedColumns = ["city"]
        }
        await search(model, "acme")
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
    func hideClears() async {
        let (model, owner) = mount { $0.isEditable = true }
        model.findInColumn(Self.company, replace: true)
        model.find.term = "acme"
        model.findQueryDidChange()
        await model.findSearchSettled()
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
    func searchAllRows() async {
        let (plain, plainOwner) = mount()
        await search(plain, "  zzz ")
        plain.searchAllRows()
        #expect(plainOwner.searchedTerms.isEmpty)
        #expect(plain.find.isVisible)

        let (offered, owner) = mount { $0.commands = [.searchAllRows] }
        await search(offered, "  zzz ")
        offered.searchAllRows()
        #expect(owner.searchedTerms == ["zzz"])
        #expect(offered.find.isVisible == false)
    }

    @Test("Search All Rows waits for plain options, since the server matches the term as typed in any column")
    func searchAllRowsNeedsPlainOptions() async {
        let (model, owner) = mount { $0.commands = [.searchAllRows] }
        await search(model, "^zzz$")
        model.find.options.usesRegularExpression = true

        model.searchAllRows()
        #expect(owner.searchedTerms.isEmpty)
        #expect(!model.searchAllRowsKeepsTheOptions)

        model.find.options.usesRegularExpression = false
        model.searchAllRows()
        #expect(owner.searchedTerms == ["^zzz$"])
    }

    @Test("New rows under an open bar are searched again")
    func reloadSearchesTheNewRows() async {
        let (model, owner) = mount()
        await search(model, "acme")
        #expect(model.find.matches.count == 4)

        owner.tableRows = TableRows.from(
            queryRows: [["9", "Acme", "Oslo"]],
            columns: ["id", "company", "city"],
            columnTypes: [.integer(rawType: "INT"), .text(rawType: "TEXT"), .text(rawType: "TEXT")]
        )
        model.reloadRows()
        await model.findSearchSettled()

        #expect(model.find.matches.count == 1)
    }

    private func fullSearch(_ model: DataGridModel, _ owner: FindGridOwner) -> [GridFindState.Match] {
        let source = GridFindEngine.Source(rows: owner.tableRows, order: model.order, columns: model.columns)
        return GridFindEngine.search(model.find.term, options: model.find.options, in: source).matches
    }

    @Test("Edits under an open bar keep the matches a full search finds")
    func editsKeepTheMatchesInStep() async {
        let (model, owner) = mount()
        await search(model, "acme")

        owner.tableRows.rows[2].values[1] = .text("Umbrella")
        model.apply(.cellChanged(row: 2, column: 1))
        owner.tableRows.rows[0].values[2] = .text("Acme Heights")
        owner.tableRows.rows[1].values[2] = .text("Falls")
        model.apply(.cellsChanged([CellPosition(row: 0, column: 2), CellPosition(row: 1, column: 2)]))

        #expect(model.find.matches == [match(0, Self.city), match(3, Self.company), match(3, Self.city)])
        #expect(model.find.matches == fullSearch(model, owner))
    }

    @Test("Rows added or removed under an open bar keep the matches a full search finds")
    func insertsAndRemovalsKeepTheMatchesInStep() async {
        let (model, owner) = mount()
        await search(model, "acme")

        let inserted = owner.tableRows.appendInsertedRow(values: [.text("5"), .text("Acme East"), .text("Oslo")])
        model.apply(inserted)
        let insertedID = owner.tableRows.rows[4].id
        #expect(model.find.matches.last == GridFindState.Match(rowID: insertedID, columnID: Self.company))
        #expect(model.find.matches == fullSearch(model, owner))

        let removed = owner.tableRows.remove(at: IndexSet(integer: 1))
        model.apply(removed)

        #expect(model.find.matches == [
            match(2, Self.company),
            match(3, Self.company),
            match(3, Self.city),
            GridFindState.Match(rowID: insertedID, columnID: Self.company)
        ])
        #expect(model.find.matches == fullSearch(model, owner))
    }

    // An edit keeps its row on screen (#2667); an insert hides it, and once undone and inserted again it shows again.
    @Test("A row a value filter shows again after an insert is searched again")
    func rowBackInTheFilteredOrderIsSearched() async {
        let (model, owner) = mount()
        var filter = GridValueFilterState()
        filter.set(
            ColumnValueFilter(selectedValues: ["Acme Falls", "Paris", "Acme"], includesNull: false),
            columnName: "city",
            forColumn: 2
        )
        model.setValueFilter(filter)
        await search(model, "acme")
        #expect(model.find.matches == [match(1, Self.city), match(2, Self.company), match(3, Self.company), match(3, Self.city)])

        owner.tableRows.rows[2].values[2] = .text("Lyon")
        model.apply(.cellChanged(row: 2, column: 2))
        let firstRow = owner.tableRows.appendInsertedRow(values: [.text("5"), .text("Nova"), .text("Oslo")])
        model.apply(firstRow)
        #expect(model.displayIndex(of: .existing(2)) == nil)
        let firstRowID = owner.tableRows.rows[4].id
        model.apply(owner.tableRows.remove(rowIDs: [firstRowID]))
        owner.tableRows.rows[2].values[2] = .text("Paris")
        model.apply(.cellChanged(row: 2, column: 2))
        let secondRow = owner.tableRows.appendInsertedRow(values: [.text("6"), .text("Vega"), .text("Oslo")])
        model.apply(secondRow)

        #expect(model.displayIndex(of: .existing(2)) != nil)
        #expect(model.find.matches == [match(1, Self.city), match(2, Self.company), match(3, Self.company), match(3, Self.city)])
        #expect(model.find.matches == fullSearch(model, owner))
    }

    @Test("A term typed but not yet searched makes the next refresh search every row")
    func changedTermSearchesEveryRow() async {
        let (model, owner) = mount()
        await search(model, "acme")

        model.find.term = "paris"
        owner.tableRows.rows[0].values[2] = .text("Paris")
        model.apply(.cellChanged(row: 3, column: 1))
        await model.findSearchSettled()

        #expect(model.find.matches == [match(0, Self.city), match(2, Self.city)])
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
    func useSelectionForFind() async {
        let (model, owner) = mount()
        model.setSelection(cell(0, 2))
        model.find.options.usesRegularExpression = true

        model.useSelectionForFind()
        await model.findSearchSettled()

        #expect(model.find.isVisible)
        #expect(model.find.term == NSRegularExpression.escapedPattern(for: "St. Louis"))
        #expect(model.find.matches == [GridFindState.Match(rowID: .existing(0), columnID: DataGridColumnID(name: "city", occurrence: 0))])
        #expect(owner.commits.isEmpty)
    }

    // MARK: - A search off the main actor

    // Each test ends on `owner`: the model holds its data source weakly, and without it the grid has no rows.

    @Test("A typed term drops the old term's matches at once, and a refresh keeps its matches until its search lands")
    func typedTermDropsTheOldMatches() async {
        let (model, owner) = mount()
        await search(model, "paris")

        model.find.term = "acme"
        model.findQueryDidChange()

        #expect(model.find.loadedRowsSearch != nil)
        #expect(model.find.isSearching == false)
        #expect(model.find.matches.isEmpty)
        #expect(model.find.currentIndex == nil)

        await model.findSearchSettled()

        #expect(model.find.loadedRowsSearch == nil)
        #expect(model.find.matches.count == 4)
        #expect(model.selection.activeCell == GridCoord(row: 3, displayColumn: 1))

        model.refreshFind()

        #expect(model.find.loadedRowsSearch != nil)
        #expect(model.find.matches.count == 4)
        #expect(model.find.currentIndex == 2)

        await model.findSearchSettled()
        #expect(model.find.currentIndex == 2)
        #expect(owner.commits.isEmpty)
    }

    @Test("A typed term drops the old term's invalid-pattern message at once")
    func typedTermDropsTheOldProblem() async {
        let (model, owner) = mount()
        model.showFind()
        model.find.options.usesRegularExpression = true
        model.find.term = "["
        model.findQueryDidChange()
        #expect(model.find.problem != nil)

        model.find.term = "acme"
        model.findQueryDidChange()

        #expect(model.find.loadedRowsSearch != nil)
        #expect(model.find.problem == nil)

        await model.findSearchSettled()
        #expect(model.find.problem == nil)
        #expect(owner.commits.isEmpty)
    }

    @Test("Of two terms typed in quick succession only the second one's matches land")
    func onlyTheLastTermLands() async throws {
        let (model, owner) = mount()
        model.showFind()
        model.find.term = "acme"
        model.findQueryDidChange()
        let first = try #require(model.find.loadedRowsSearch)

        model.find.term = "paris"
        model.findQueryDidChange()
        await model.findSearchSettled()

        #expect(first.isCancelled)
        #expect(model.find.matches == [match(2, Self.city)])
        #expect(model.selection.activeCell == GridCoord(row: 2, displayColumn: 2))
        #expect(owner.commits.isEmpty)
    }

    @Test("A row added while a search runs is among the matches that land")
    func rowAddedDuringASearchIsFound() async throws {
        let (model, owner) = mount()
        model.showFind()
        model.find.term = "acme"
        model.findQueryDidChange()
        let running = try #require(model.find.loadedRowsSearch)

        model.apply(owner.tableRows.appendInsertedRow(values: [.text("5"), .text("Acme East"), .text("Oslo")]))
        await model.findSearchSettled()

        let insertedID = owner.tableRows.rows[4].id
        #expect(running.isCancelled)
        #expect(model.find.matches.last == GridFindState.Match(rowID: insertedID, columnID: Self.company))
        #expect(model.find.matches == fullSearch(model, owner))
        #expect(model.selection.activeCell == GridCoord(row: 1, displayColumn: 2), "the typed term still lands on its first match")
    }

    @Test("A typed term's matches land without moving a cursor the user moved during the search")
    func landingKeepsAMovedCursor() async {
        let (model, owner) = mount()
        model.showFind()
        model.find.term = "acme"
        model.findQueryDidChange()

        model.setSelection(cell(0, 0))
        await model.findSearchSettled()

        #expect(model.find.matches.count == 4)
        #expect(model.find.currentIndex == 0)
        #expect(model.selection.activeCell == GridCoord(row: 0, displayColumn: 0))
        #expect(owner.commits.isEmpty)
    }

    @Test("Find Next pressed while a search runs steps once its matches land")
    func findNextWaitsForTheSearch() async {
        let (model, owner) = mount()
        model.showFind()
        model.find.term = "acme"
        model.findQueryDidChange()

        model.findNext()
        #expect(model.selection.activeCell == nil)

        await model.findSearchSettled()

        #expect(model.find.currentIndex == 1)
        #expect(model.selection.activeCell == GridCoord(row: 2, displayColumn: 1))
        #expect(owner.commits.isEmpty)
    }

    @Test("Every Find Next and Find Previous pressed while a search runs counts once its matches land")
    func deferredStepsAreCounted() async {
        let (model, owner) = mount()
        model.showFind()
        model.find.term = "acme"
        model.findQueryDidChange()

        model.findNext()
        model.findNext()
        model.findNext()
        model.findPrevious()
        await model.findSearchSettled()

        #expect(model.find.currentIndex == 2)
        #expect(model.selection.activeCell == GridCoord(row: 3, displayColumn: 1))
        #expect(owner.commits.isEmpty)
    }

    @Test("Replace pressed while a search runs replaces the match that search lands on")
    func replaceWaitsForTheRunningSearch() async {
        let (model, owner) = mount { $0.isEditable = true }
        await search(model, "paris")
        model.find.term = "acme"
        model.findQueryDidChange()
        model.find.replacement = "Umbrella"

        model.replaceCurrentMatch()

        #expect(model.find.loadedRowsSearch == nil)
        #expect(owner.commits.first?.edits.map { $0.rowID } == [.existing(3)])
        #expect(owner.commits.first?.edits.map { $0.newValue } == [.text("Umbrella Corp")])
    }

    @Test("The bar says No matches and offers Search All Rows only once the search lands")
    func noMatchesWaitsForTheSearch() async {
        let (model, owner) = mount { $0.commands = [.searchAllRows] }
        model.showFind()
        model.find.term = "zzz"
        model.findQueryDidChange()

        #expect(model.find.isAwaitingLoadedRows)
        #expect(DataGridFindBar.counterText(status: nil, model: model).isEmpty)
        #expect(!DataGridFindBar.showsSearchAllRows(offered: model.offersSearchAllRows, model: model))

        await model.findSearchSettled()

        #expect(!model.find.isAwaitingLoadedRows)
        #expect(DataGridFindBar.counterText(status: nil, model: model) == String(localized: "No matches"))
        #expect(DataGridFindBar.showsSearchAllRows(offered: model.offersSearchAllRows, model: model))

        model.find.term = ""
        model.findQueryDidChange()

        #expect(!model.find.isAwaitingLoadedRows, "an empty term is answered without a search")
        #expect(model.find.loadedRowsSearch == nil)
        #expect(owner.commits.isEmpty)
    }

    @Test("A grid that goes away cancels the search still running")
    func releasedModelCancelsTheSearch() throws {
        let owner: FindGridOwner
        let running: Task<Void, Never>
        weak var released: DataGridModel?
        do {
            let (model, mounted) = mount()
            owner = mounted
            model.showFind()
            model.find.term = "acme"
            model.findQueryDidChange()
            running = try #require(model.find.loadedRowsSearch)
            released = model
        }

        #expect(released == nil)
        #expect(running.isCancelled)
        #expect(owner.commits.isEmpty)
    }
}
