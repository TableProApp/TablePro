// Guards the invariants behind the autocomplete delegate-lifetime fix:
// the completion engine produces keyword suggestions before any schema is
// attached, and reconfiguring the adapter across nil/non-nil schema transitions
// keeps it functional. The SwiftUI onDisappear/onAppear delegate attachment that
// caused the original dropout is an AppKit lifecycle behaviour and is not
// deterministically unit-testable; these tests cover the logic the fix relies on.

import Foundation
@testable import TablePro
@testable import TableProAutocomplete
import TableProEditorKit
import TableProPluginKit
import TableProTextEngine
import Testing

extension GlobalStateSuites {
    struct QueryCompletionAdapterLifecycleTests {
        @Test("engine returns keyword completions with no schema provider")
        func keywordsAvailableWithoutSchema() async {
            let engine = CompletionEngine(schemaProvider: nil, databaseType: .postgresql)
            let context = await engine.getCompletions(text: "SEL", cursorPosition: 3)
            #expect(context?.items.contains { $0.label == "SELECT" } == true)
        }

        @Test("engine returns keyword completions with no schema and no database type")
        func keywordsAvailableWithoutSchemaOrDatabaseType() async {
            let engine = CompletionEngine(schemaProvider: nil, databaseType: nil)
            let context = await engine.getCompletions(text: "SEL", cursorPosition: 3)
            #expect(context?.items.contains { $0.label == "SELECT" } == true)
        }

        @MainActor
        @Test("configure across nil and non-nil schema keeps the adapter functional")
        func configureAcrossSchemaTransitionsKeepsAdapterUsable() {
            let adapter = QueryCompletionAdapter(schemaProvider: nil, databaseType: nil)
            #expect(!adapter.completionTriggerCharacters().isEmpty)

            adapter.configure(schemaProvider: nil, databaseType: .postgresql)
            adapter.configure(schemaProvider: SQLSchemaProvider(), databaseType: .postgresql)
            adapter.configure(schemaProvider: nil, databaseType: .mysql)

            #expect(!adapter.completionTriggerCharacters().isEmpty)
        }

        /// Rebuilding the service drops the open completion session. A refresh in any window of the
        /// connection bumps the profile revision the editor's task keys on, so an unconditional
        /// rebuild closed the popup under whoever was typing.
        @MainActor
        @Test("configuring with unchanged inputs does not rebuild the service")
        func configureWithUnchangedInputsKeepsTheService() {
            let provider = SQLSchemaProvider()
            let adapter = QueryCompletionAdapter(schemaProvider: provider, databaseType: .postgresql)
            let profile = QueryCompletionProfile(
                resolvedDialect: nil,
                statementCompletions: [],
                revision: "rev-1"
            )
            adapter.configure(schemaProvider: provider, databaseType: .postgresql, profile: profile)
            let first = adapter.serviceIdentityForTesting

            adapter.configure(schemaProvider: provider, databaseType: .postgresql, profile: profile)

            #expect(adapter.serviceIdentityForTesting == first)
        }

        @MainActor
        @Test("a changed profile revision rebuilds the service")
        func changedProfileRevisionRebuildsTheService() {
            let provider = SQLSchemaProvider()
            let adapter = QueryCompletionAdapter(schemaProvider: provider, databaseType: .postgresql)
            adapter.configure(
                schemaProvider: provider,
                databaseType: .postgresql,
                profile: QueryCompletionProfile(resolvedDialect: nil, statementCompletions: [], revision: "rev-1")
            )
            let first = adapter.serviceIdentityForTesting

            adapter.configure(
                schemaProvider: provider,
                databaseType: .postgresql,
                profile: QueryCompletionProfile(resolvedDialect: nil, statementCompletions: [], revision: "rev-2")
            )

            #expect(adapter.serviceIdentityForTesting != first)
        }

        @MainActor
        @Test("a changed schema provider rebuilds the service")
        func changedSchemaProviderRebuildsTheService() {
            let adapter = QueryCompletionAdapter(schemaProvider: SQLSchemaProvider(), databaseType: .postgresql)
            adapter.configure(schemaProvider: SQLSchemaProvider(), databaseType: .postgresql)
            let first = adapter.serviceIdentityForTesting

            adapter.configure(schemaProvider: SQLSchemaProvider(), databaseType: .postgresql)

            #expect(adapter.serviceIdentityForTesting != first)
        }

        // MARK: - Incremental ranking (#2444)

        /// The popup preselects its first row on every incremental update, so a list still ordered for
        /// the prefix it opened with is what Return commits. Every pair here opened with the function
        /// correctly ahead of the keyword, and has to swap once the typed token completes the keyword.
        @MainActor
        @Test(
            "typing to an exact keyword puts it first",
            .upperCaseKeywords,
            arguments: [
                (opening: "t", typed: "true", exact: "TRUE", longer: "TRUNCATE"),
                (opening: "n", typed: "null", exact: "NULL", longer: "NULLIF"),
                (opening: "i", typed: "in", exact: "IN", longer: "INSTR"),
                (opening: "i", typed: "is", exact: "IS", longer: "ISNULL"),
                (opening: "r", typed: "regexp", exact: "REGEXP", longer: "REGEXP_REPLACE")
            ]
        )
        func incrementalUpdatePutsTheExactKeywordFirst(
            opening: String,
            typed: String,
            exact: String,
            longer: String
        ) async {
            let labels = await incrementalLabels(opening: opening, typed: typed)

            #expect(labels.first == exact)
            if let exactIndex = labels.firstIndex(of: exact), let longerIndex = labels.firstIndex(of: longer) {
                #expect(exactIndex < longerIndex)
            }
        }

        /// The reporter's own A/B: dismissing the popup and reopening it on the complete token gave the
        /// right order, so an incremental update has to arrive at the same answer.
        @MainActor
        @Test("typing into an open popup lands where reopening it would", .upperCaseKeywords)
        func incrementalUpdateMatchesAFreshRequest() async {
            let opened = "SELECT * FROM gt_user WHERE t"
            let completed = "SELECT * FROM gt_user WHERE true"

            let controller = EditorControllerFixture.make(string: opened)
            let adapter = QueryCompletionAdapter(schemaProvider: nil, databaseType: .mysql)
            _ = await adapter.completionSuggestionsRequested(
                textView: controller,
                cursorPosition: cursor(atEndOf: opened),
                isManualTrigger: false
            )

            controller.textView.setText(completed)
            for length in (opened.utf16.count + 1)...completed.utf16.count {
                _ = adapter.completionOnCursorMove(
                    textView: controller,
                    cursorPosition: CursorPosition(range: NSRange(location: length, length: 0))
                )
            }
            let incremental = adapter.completionOnCursorMove(
                textView: controller,
                cursorPosition: cursor(atEndOf: completed)
            )?.map(\.label)

            let freshController = EditorControllerFixture.make(string: completed)
            let freshAdapter = QueryCompletionAdapter(schemaProvider: nil, databaseType: .mysql)
            let fresh = await freshAdapter.completionSuggestionsRequested(
                textView: freshController,
                cursorPosition: cursor(atEndOf: completed),
                isManualTrigger: false
            )?.items.map(\.label)

            #expect(incremental?.first == "TRUE")
            #expect(incremental?.first == fresh?.first)
        }

        /// Deleting a character has to widen the list again, which it only does when each update is
        /// resolved from the session's own candidates rather than from the previous keystroke's.
        @MainActor
        @Test("deleting a character widens the list again", .upperCaseKeywords)
        func deletingACharacterWidensTheList() async {
            let opened = "SELECT * FROM gt_user WHERE t"
            let controller = EditorControllerFixture.make(string: opened)
            let adapter = QueryCompletionAdapter(schemaProvider: nil, databaseType: .mysql)
            _ = await adapter.completionSuggestionsRequested(
                textView: controller,
                cursorPosition: cursor(atEndOf: opened),
                isManualTrigger: false
            )

            let narrow = "SELECT * FROM gt_user WHERE trun"
            controller.textView.setText(narrow)
            let narrowed = adapter.completionOnCursorMove(
                textView: controller,
                cursorPosition: cursor(atEndOf: narrow)
            )?.map(\.label) ?? []

            let wide = "SELECT * FROM gt_user WHERE tr"
            controller.textView.setText(wide)
            let widened = adapter.completionOnCursorMove(
                textView: controller,
                cursorPosition: cursor(atEndOf: wide)
            )?.map(\.label) ?? []

            #expect(!narrowed.isEmpty)
            #expect(widened.count > narrowed.count)
            #expect(widened.contains("TRUE"))
        }

        // MARK: - The session pool

        /// An open popup re-ranks against what the session kept rather than asking again, so the
        /// session keeps more candidates than the popup shows. It still keeps a bounded number: ranking
        /// walks every one of them on every keystroke.
        @MainActor
        @Test("an open session re-ranks a bounded pool wider than the visible list")
        func openSessionReranksABoundedPool() async {
            let items = (0..<5_000).map { SQLCompletionItem.keyword(String(format: "ab%04d", $0)) }
            let service = RankingInputRecordingCompletionService(items: items, poolLimit: 400)
            let adapter = QueryCompletionAdapter(serviceForTesting: service)
            let controller = EditorControllerFixture.make(string: "a")

            _ = await adapter.completionSuggestionsRequested(
                textView: controller,
                cursorPosition: CursorPosition(range: NSRange(location: 1, length: 0)),
                isManualTrigger: false
            )

            controller.textView.setText("ab")
            _ = adapter.completionOnCursorMove(
                textView: controller,
                cursorPosition: CursorPosition(range: NSRange(location: 2, length: 0))
            )
            controller.textView.setText("ab0")
            _ = adapter.completionOnCursorMove(
                textView: controller,
                cursorPosition: CursorPosition(range: NSRange(location: 3, length: 0))
            )

            #expect(service.rankingInputCounts == [400, 400])
        }

        // The pool after `FROM ` is t000 to t399, so a re-rank for `t45` offers t045 and never reaches t450.
        @MainActor
        @Test("a narrowing keystroke on a cut pool keeps the re-rank and asks the whole catalog behind it")
        func cutPoolAsksTheWholeCatalogBehindTheRerank() async {
            let provider = await schema((0..<500).map { String(format: "t%03d", $0) })
            let adapter = QueryCompletionAdapter(schemaProvider: provider, databaseType: .mysql)
            let opened = "SELECT * FROM "
            let controller = EditorControllerFixture.make(string: opened)
            _ = await adapter.completionSuggestionsRequested(
                textView: controller,
                cursorPosition: cursor(atEndOf: opened),
                isManualTrigger: false
            )

            let narrowed = "SELECT * FROM t45"
            controller.textView.setText(narrowed)
            let reranked = adapter.completionOnCursorMove(
                textView: controller,
                cursorPosition: cursor(atEndOf: narrowed)
            )?.map(\.label) ?? []
            let narrowedNeedsFreshItems = adapter.completionNeedsFreshItems(
                textView: controller,
                cursorPosition: cursor(atEndOf: narrowed)
            )
            let fresh = await adapter.completionSuggestionsRequested(
                textView: controller,
                cursorPosition: cursor(atEndOf: narrowed),
                isManualTrigger: false
            )?.items.map(\.label) ?? []
            controller.textView.setText(narrowed + "0")
            let freshNeedsFreshItems = adapter.completionNeedsFreshItems(
                textView: controller,
                cursorPosition: cursor(atEndOf: narrowed + "0")
            )

            #expect(!reranked.isEmpty)
            #expect(narrowedNeedsFreshItems)
            #expect(fresh.first == "t450")
            #expect(!freshNeedsFreshItems)
        }

        // A pool ranked for `ab` holds no `ac1`, so deleting back to `a` has to ask again.
        @MainActor
        @Test("a pool answers a prefix that extends the one it was ranked for, and asks again for a shorter one")
        func poolAsksAgainForAShorterPrefix() async {
            let provider = await schema(["ab1", "ab2", "ac1"])
            let adapter = QueryCompletionAdapter(schemaProvider: provider, databaseType: .mysql)
            let opened = "SELECT * FROM ab"
            let controller = EditorControllerFixture.make(string: opened)
            _ = await adapter.completionSuggestionsRequested(
                textView: controller,
                cursorPosition: cursor(atEndOf: opened),
                isManualTrigger: false
            )

            controller.textView.setText(opened + "1")
            let longerNeedsFreshItems = adapter.completionNeedsFreshItems(
                textView: controller,
                cursorPosition: cursor(atEndOf: opened + "1")
            )
            let shorter = "SELECT * FROM a"
            controller.textView.setText(shorter)
            let shorterNeedsFreshItems = adapter.completionNeedsFreshItems(
                textView: controller,
                cursorPosition: cursor(atEndOf: shorter)
            )

            #expect(!longerNeedsFreshItems)
            #expect(shorterNeedsFreshItems)
        }

        // MARK: - The session's token

        @MainActor
        @Test("a session re-ranks its own token and declines the next one")
        func sessionDeclinesACursorOnAnotherToken() async {
            let service = TokenBoundCompletionService(labels: ["select", "set", "update", "users"])
            let adapter = QueryCompletionAdapter(serviceForTesting: service)
            let controller = EditorControllerFixture.make(string: "se")

            _ = await adapter.completionSuggestionsRequested(
                textView: controller,
                cursorPosition: cursor(atEndOf: "se"),
                isManualTrigger: false
            )

            controller.textView.setText("sel")
            let sameToken = adapter.completionOnCursorMove(
                textView: controller,
                cursorPosition: cursor(atEndOf: "sel")
            )?.map(\.label)

            controller.textView.setText("se u")
            let nextToken = adapter.completionOnCursorMove(
                textView: controller,
                cursorPosition: cursor(atEndOf: "se u")
            )?.map(\.label)

            #expect(sameToken == ["select"])
            #expect(nextToken == nil)
        }

        @MainActor
        @Test("a response names the prefix it was ranked for, not the text the editor holds when it lands")
        func responseNamesThePrefixItWasRankedFor() async {
            let controller = EditorControllerFixture.make(string: "sl")
            let service = TokenBoundCompletionService(labels: ["sleep", "select", "set"])
            service.whileAnswering = { controller.textView.setText("se") }
            let adapter = QueryCompletionAdapter(serviceForTesting: service)

            let response = await adapter.completionSuggestionsRequested(
                textView: controller,
                cursorPosition: cursor(atEndOf: "sl"),
                isManualTrigger: false
            )

            #expect(controller.textView.string == "se")
            #expect(response?.prefix == CodeSuggestionPrefix(range: NSRange(location: 0, length: 2), text: "sl"))
            #expect(response?.windowPosition.range == NSRange(location: 2, length: 0))
        }

        // MARK: - A quoted name with a space

        // The token start was a walk back that stops at the space: `[Order Det]` became `[Order Order Details]`.
        @MainActor
        @Test("accepting inside a bracketed name with a space replaces the whole name and steps past the close")
        func acceptInsideABracketedNameWithASpace() async throws {
            let controller = EditorControllerFixture.make(string: "SELECT * FROM [Order Det]")
            let provider = await schema(["Details", "Order Details"])
            let adapter = QueryCompletionAdapter(schemaProvider: provider, databaseType: .mssql)
            let caret = CursorPosition(range: NSRange(location: 24, length: 0))

            let response = await adapter.completionSuggestionsRequested(
                textView: controller,
                cursorPosition: caret,
                isManualTrigger: false
            )
            let first = try #require(response?.items.first)
            #expect(first.label == "Order Details")
            #expect(response?.prefix == CodeSuggestionPrefix(range: NSRange(location: 15, length: 9), text: "Order Det"))

            adapter.completionWindowApplyCompletion(item: first, textView: controller, cursorPosition: caret)

            #expect(controller.textView.string == "SELECT * FROM [Order Details]")
            #expect(controller.cursorPositions.first?.range == NSRange(location: 29, length: 0))
        }

        @MainActor
        @Test("a space typed inside a bracketed name keeps the session and ranks on the whole name")
        func spaceInsideABracketedNameKeepsTheSession() async {
            let controller = EditorControllerFixture.make(string: "SELECT * FROM [Order]")
            let provider = await schema(["Order Details", "Orders"])
            let adapter = QueryCompletionAdapter(schemaProvider: provider, databaseType: .mssql)
            _ = await adapter.completionSuggestionsRequested(
                textView: controller,
                cursorPosition: CursorPosition(range: NSRange(location: 20, length: 0)),
                isManualTrigger: false
            )

            controller.textView.setText("SELECT * FROM [Order ]")
            let reranked = adapter.completionOnCursorMove(
                textView: controller,
                cursorPosition: CursorPosition(range: NSRange(location: 21, length: 0))
            )?.map(\.label)

            #expect(reranked == ["Order Details"])
        }

        @MainActor
        @Test("accepting inside an open backtick name closes it")
        func acceptInsideAnOpenBacktickNameClosesIt() async throws {
            let controller = EditorControllerFixture.make(string: "SELECT * FROM `Order Det")
            let provider = await schema(["Details", "Order Details"])
            let adapter = QueryCompletionAdapter(schemaProvider: provider, databaseType: .mysql)
            let caret = CursorPosition(range: NSRange(location: 24, length: 0))

            let response = await adapter.completionSuggestionsRequested(
                textView: controller,
                cursorPosition: caret,
                isManualTrigger: false
            )
            let first = try #require(response?.items.first)
            #expect(first.label == "Order Details")

            adapter.completionWindowApplyCompletion(item: first, textView: controller, cursorPosition: caret)

            #expect(controller.textView.string == "SELECT * FROM `Order Details`")
            #expect(controller.cursorPositions.first?.range == NSRange(location: 29, length: 0))
        }

        @MainActor
        @Test("accepting a column whose name holds a dot keeps it inside the quotes")
        func dottedColumnStaysQuoted() async throws {
            let source = SQLSchemaProvider.ColumnMetadataSource(
                fetchColumns: { _, _ in [TestFixtures.makeColumnInfo(name: "order.total")] },
                fetchAllColumns: { [:] }
            )
            let provider = SQLSchemaProvider(metadataSource: source)
            await provider.updateTables([TestFixtures.makeTableInfo(name: "t")])
            let controller = EditorControllerFixture.make(string: #"SELECT "ord" FROM t"#)
            let adapter = QueryCompletionAdapter(schemaProvider: provider, databaseType: .postgresql)
            let caret = CursorPosition(range: NSRange(location: 11, length: 0))

            let response = await adapter.completionSuggestionsRequested(
                textView: controller,
                cursorPosition: caret,
                isManualTrigger: false
            )
            let item = try #require(response?.items.first { $0.label == "order.total" })
            adapter.completionWindowApplyCompletion(item: item, textView: controller, cursorPosition: caret)

            #expect(controller.textView.string == #"SELECT "order.total" FROM t"#)
        }

        @MainActor
        @Test("accepting a table-qualified column inside quotes replaces the quotes")
        func qualifiedColumnReplacesTheQuotes() async throws {
            let source = SQLSchemaProvider.ColumnMetadataSource(
                fetchColumns: { table, _ in
                    [TestFixtures.makeColumnInfo(name: table == "orders" ? "total" : "name")]
                },
                fetchAllColumns: { [:] }
            )
            let provider = SQLSchemaProvider(metadataSource: source)
            await provider.updateTables([
                TestFixtures.makeTableInfo(name: "orders"), TestFixtures.makeTableInfo(name: "customers")
            ])
            let controller = EditorControllerFixture.make(string: #"SELECT "to" FROM orders o, customers c"#)
            let adapter = QueryCompletionAdapter(schemaProvider: provider, databaseType: .postgresql)
            let caret = CursorPosition(range: NSRange(location: 10, length: 0))

            let response = await adapter.completionSuggestionsRequested(
                textView: controller,
                cursorPosition: caret,
                isManualTrigger: false
            )
            let item = try #require(response?.items.first { $0.label == "o.total" })
            adapter.completionWindowApplyCompletion(item: item, textView: controller, cursorPosition: caret)

            #expect(controller.textView.string == "SELECT o.total FROM orders o, customers c")
        }

        // MARK: - Saved query templates

        @MainActor
        @Test("accepting a saved query with fields expands it, selects the first field and keeps $1")
        func favoriteWithFieldsStartsASnippet() async throws {
            let controller = EditorControllerFixture.make(string: "upd")
            let adapter = QueryCompletionAdapter(schemaProvider: nil, databaseType: .postgresql)
            adapter.updateFavoriteKeywords(["upd": (name: "Update", query: "UPDATE ${1:t} SET ${2:c} = $1;;")])
            let caret = CursorPosition(range: NSRange(location: 3, length: 0))

            let response = await adapter.completionSuggestionsRequested(
                textView: controller,
                cursorPosition: caret,
                isManualTrigger: true
            )
            let item = try #require(response?.items.first { $0.label == "upd" })
            adapter.completionWindowApplyCompletion(item: item, textView: controller, cursorPosition: caret)

            #expect(controller.textView.string == "UPDATE t SET c = $1")
            #expect(controller.isSnippetSessionActive)
            #expect(controller.textView.selectionManager.textSelections.map { $0.range } == [NSRange(location: 7, length: 1)])
        }

        @MainActor
        @Test("accepting a saved query with only ;; places the caret as before")
        func favoriteWithMarkerPlacesTheCaret() async throws {
            let controller = EditorControllerFixture.make(string: "cnt")
            let adapter = QueryCompletionAdapter(schemaProvider: nil, databaseType: .postgresql)
            adapter.updateFavoriteKeywords(["cnt": (name: "Count", query: "SELECT COUNT(*) FROM ;; WHERE 1")])
            let caret = CursorPosition(range: NSRange(location: 3, length: 0))

            let response = await adapter.completionSuggestionsRequested(
                textView: controller,
                cursorPosition: caret,
                isManualTrigger: true
            )
            let item = try #require(response?.items.first { $0.label == "cnt" })
            adapter.completionWindowApplyCompletion(item: item, textView: controller, cursorPosition: caret)

            #expect(controller.textView.string == "SELECT COUNT(*) FROM  WHERE 1")
            #expect(controller.isSnippetSessionActive == false)
            #expect(controller.textView.selectionManager.textSelections.map { $0.range } == [NSRange(location: 21, length: 0)])
        }

        // MARK: - Helpers

        @MainActor
        private func cursor(atEndOf text: String) -> CursorPosition {
            CursorPosition(range: NSRange(location: text.utf16.count, length: 0))
        }

        private func schema(_ tables: [String]) async -> SQLSchemaProvider {
            let provider = SQLSchemaProvider()
            await provider.updateTables(tables.map { TestFixtures.makeTableInfo(name: $0) })
            return provider
        }


        @MainActor
        private func incrementalLabels(opening: String, typed: String) async -> [String] {
            let queryPrefix = "SELECT * FROM gt_user WHERE "
            let openingQuery = queryPrefix + opening
            let controller = EditorControllerFixture.make(string: openingQuery)
            let adapter = QueryCompletionAdapter(schemaProvider: nil, databaseType: .mysql)

            _ = await adapter.completionSuggestionsRequested(
                textView: controller,
                cursorPosition: cursor(atEndOf: openingQuery),
                isManualTrigger: false
            )

            let typedQuery = queryPrefix + typed
            controller.textView.setText(typedQuery)

            return adapter.completionOnCursorMove(
                textView: controller,
                cursorPosition: cursor(atEndOf: typedQuery)
            )?.map(\.label) ?? []
        }
    }
}

/// A completion's label follows `SQLKeywordCase`, so every ranking assertion written against a
/// spelling would otherwise answer to whatever the machine running it has chosen: the same tests
/// pass on a developer set to UPPERCASE and fail on CI, which follows the lowercase prefix typed.
private extension Trait where Self == AppSettingsTrait {
    static var upperCaseKeywords: Self { .appSettings { $0.editor.keywordCase = .upper } }
}

@MainActor
private final class TokenBoundCompletionService: QueryCompletionService {
    private let items: [SQLCompletionItem]
    var whileAnswering: (@MainActor () -> Void)?

    init(labels: [String]) {
        items = labels.map { SQLCompletionItem.keyword($0) }
    }

    var triggerCharacters: Set<String> { [] }

    func completions(
        in text: NSString,
        at offset: Int,
        isManualTrigger: Bool
    ) async -> QueryCompletionSession? {
        _ = isManualTrigger
        let start = tokenStart(in: text, endingAt: offset)
        whileAnswering?()
        return QueryCompletionSession(
            items: items,
            candidates: items,
            replacementRange: NSRange(location: start, length: offset - start)
        )
    }

    func rank(_ items: [SQLCompletionItem], prefix: String) -> [SQLCompletionItem] {
        let lowerPrefix = prefix.lowercased()
        return items.filter { $0.filterText.hasPrefix(lowerPrefix) }
    }

    func tokenStart(in text: NSString, endingAt offset: Int) -> Int {
        SQLTokenBoundary.segmentStart(in: text, endingAt: offset)
    }

    func updateFavoriteKeywords(_ keywords: [String: (name: String, query: String)]) {
        _ = keywords
    }
}

/// Records what each incremental update was asked to rank, so a test can pin the pool's bound
/// without reaching into the adapter's private session.
@MainActor
private final class RankingInputRecordingCompletionService: QueryCompletionService {
    private let items: [SQLCompletionItem]
    private let poolLimit: Int
    private(set) var rankingInputCounts: [Int] = []

    init(items: [SQLCompletionItem], poolLimit: Int) {
        self.items = items
        self.poolLimit = poolLimit
    }

    var triggerCharacters: Set<String> { [] }

    func completions(
        in text: NSString,
        at offset: Int,
        isManualTrigger: Bool
    ) async -> QueryCompletionSession? {
        _ = (text, offset, isManualTrigger)
        return QueryCompletionSession(
            items: Array(items.prefix(40)),
            candidates: Array(items.prefix(poolLimit)),
            replacementRange: NSRange(location: 0, length: 1)
        )
    }

    func rank(_ items: [SQLCompletionItem], prefix: String) -> [SQLCompletionItem] {
        rankingInputCounts.append(items.count)
        let lowerPrefix = prefix.lowercased()
        return items.filter { $0.filterText.hasPrefix(lowerPrefix) }
    }

    func tokenStart(in text: NSString, endingAt offset: Int) -> Int {
        _ = (text, offset)
        return 0
    }

    func updateFavoriteKeywords(_ keywords: [String: (name: String, query: String)]) {
        _ = keywords
    }
}
