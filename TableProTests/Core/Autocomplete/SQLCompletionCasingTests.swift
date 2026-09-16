//
//  SQLCompletionCasingTests.swift
//  TableProTests
//
//  Tests for SQLCompletionCasing: which completion items follow the typed case,
//  how the case is read off the prefix, and which vocabularies are never touched.
//

import Foundation
@testable import TablePro
import TableProPluginKit
import Testing

@Suite("SQLCompletionCasing")
struct SQLCompletionCasingTests {
    private func applied(_ items: [SQLCompletionItem], _ prefix: String, _ policy: SQLKeywordCase = .default)
        -> [SQLCompletionItem] {
        SQLCompletionCasing.applied(to: items, typedPrefix: prefix, policy: policy)
    }

    private func first(_ keyword: String, prefix: String, policy: SQLKeywordCase = .default) -> SQLCompletionItem {
        applied([SQLCompletionItem.keyword(keyword)], prefix, policy)[0]
    }

    // MARK: - The reported behaviour

    @Test("A lowercase prefix completes to a lowercase keyword")
    func lowercasePrefix() {
        let item = first("SELECT", prefix: "sel")
        #expect(item.label == "select")
        #expect(item.insertText == "select")
    }

    @Test("An uppercase prefix completes to an uppercase keyword")
    func uppercasePrefix() {
        let item = first("SELECT", prefix: "SEL")
        #expect(item.label == "SELECT")
        #expect(item.insertText == "SELECT")
    }

    @Test("A lowercase prefix completes to a lowercase function, parentheses included")
    func lowercaseFunction() {
        let items = applied([SQLCompletionItem.function("COUNT", signature: "COUNT(expr)")], "cou")
        #expect(items[0].label == "count")
        #expect(items[0].insertText == "count()")

        let resolution = SQLCompletionInsertion.resolve(for: items[0])
        #expect(resolution.text == "count()")
        #expect(resolution.cursorOffset == 6)
    }

    @Test("An uppercase prefix completes to an uppercase function")
    func uppercaseFunction() {
        let items = applied([SQLCompletionItem.function("COUNT", signature: "COUNT(expr)")], "COU")
        #expect(items[0].insertText == "COUNT()")
    }

    // MARK: - How the case is read off the prefix

    @Test("Only the first cased character decides, so a leading capital means uppercase")
    func leadingCapital() {
        #expect(first("SELECT", prefix: "Sel").insertText == "SELECT")
    }

    @Test("A mixed prefix follows its first cased character rather than reproducing itself")
    func mixedPrefix() {
        #expect(first("SELECT", prefix: "sElE").insertText == "select")
    }

    @Test("A single character is enough to decide")
    func singleCharacter() {
        #expect(first("SELECT", prefix: "s").insertText == "select")
        #expect(first("SELECT", prefix: "S").insertText == "SELECT")
    }

    @Test("A prefix that leads with an uncased character uses the first cased one after it")
    func leadingUncasedCharacter() {
        #expect(first("SELECT", prefix: "_sel").insertText == "select")
        #expect(first("SELECT", prefix: "1SEL").insertText == "SELECT")
    }

    // MARK: - No cased character in the prefix

    @Test("An empty prefix takes the policy's fallback")
    func emptyPrefix() {
        #expect(first("SELECT", prefix: "", policy: .matchTypedElseUpper).insertText == "SELECT")
        #expect(first("SELECT", prefix: "", policy: .matchTypedElseLower).insertText == "select")
    }

    @Test("A prefix with no cased scalar takes the policy's fallback")
    func uncasedPrefix() {
        for prefix in ["_", "1", "__42", "名"] {
            #expect(first("SELECT", prefix: prefix, policy: .matchTypedElseUpper).insertText == "SELECT")
            #expect(first("SELECT", prefix: prefix, policy: .matchTypedElseLower).insertText == "select")
        }
    }

    // MARK: - The absolute policies ignore the prefix

    @Test("The absolute policies ignore what was typed")
    func absolutePolicies() {
        #expect(first("SELECT", prefix: "sel", policy: .upper).insertText == "SELECT")
        #expect(first("SELECT", prefix: "SEL", policy: .lower).insertText == "select")
    }

    // MARK: - Phrases

    @Test("A multi-word keyword is cased as one phrase")
    func multiWordKeyword() {
        #expect(first("GROUP BY", prefix: "group b").insertText == "group by")
        #expect(first("LEFT OUTER JOIN", prefix: "left o").insertText == "left outer join")
        #expect(first("IS NOT NULL", prefix: "IS N").insertText == "IS NOT NULL")
    }

    // MARK: - Vocabularies that are never re-cased

    @Test("Identifiers keep the case the catalogue reported")
    func identifiersAreNeverRecased() {
        let items = [
            SQLCompletionItem.table("MY_TABLE"),
            SQLCompletionItem.table("MyView", isView: true),
            SQLCompletionItem.column("UserID", dataType: "int"),
            SQLCompletionItem.schemaName("Public"),
            SQLCompletionItem.databaseName("AnalyticsDB")
        ]
        for prefix in ["my", "MY", "My", ""] {
            let cased = applied(items, prefix)
            #expect(cased.map(\.label) == items.map(\.label))
            #expect(cased.map(\.insertText) == items.map(\.insertText))
        }
    }

    @Test("A saved favorite keeps its keyword and its query")
    func favoritesAreNeverRecased() {
        let item = SQLCompletionItem.favorite(keyword: "slc", name: "Count", query: "SELECT COUNT(*) FROM Orders")
        let cased = applied([item], "SLC")[0]
        #expect(cased.label == "slc")
        #expect(cased.insertText == "SELECT COUNT(*) FROM Orders")
    }

    @Test("A value literal is data and keeps its case")
    func valueLiteralsAreNeverRecased() {
        var item = SQLCompletionItem(
            label: "'Active'",
            kind: .keyword,
            insertText: "'Active'",
            filterText: "active"
        )
        item.sortPriority = 10
        #expect(applied([item], "act")[0].insertText == "'Active'")
        #expect(applied([item], "ACT")[0].insertText == "'Active'")
    }

    @Test("A qualified star carries an identifier and keeps its case")
    func qualifiedStarIsNeverRecased() {
        let item = SQLCompletionItem(label: "Users.*", kind: .keyword, insertText: "Users.*")
        #expect(applied([item], "us")[0].insertText == "Users.*")
    }

    @Test("A MongoDB pipeline stage keeps its camel case")
    func mongoStagesAreNeverRecased() {
        let items = [
            SQLCompletionItem.keyword("$match", caseFolding: .fixed),
            SQLCompletionItem.keyword("$unwind", caseFolding: .fixed),
            SQLCompletionItem.function("insertOne", signature: "()", caseFolding: .fixed),
            SQLCompletionItem.operator("$gte", caseFolding: .fixed)
        ]
        for prefix in ["$MA", "$ma", "INSERT", ""] {
            #expect(applied(items, prefix).map(\.insertText) == items.map(\.insertText))
        }
    }

    @Test("A function a dialect declares case-sensitive keeps its spelling")
    func caseSensitiveDialectFunction() {
        let item = SQLCompletionItem.function("toString", signature: "toString(…)", caseFolding: .fixed)
        #expect(applied([item], "tos")[0].insertText == "toString()")
        #expect(applied([item], "TOS")[0].insertText == "toString()")
    }

    // MARK: - Invariants of the transform itself

    @Test("The label and the inserted text never disagree")
    func labelAndInsertTextAgree() {
        let items = SQLKeywords.keywordItems() + SQLKeywords.functionItems()
        for prefix in ["a", "A", "", "_"] {
            for item in applied(items, prefix) where item.insertText.hasSuffix("()") {
                #expect(item.insertText == item.label + "()")
            }
        }
    }

    @Test("The matcher's canonical text and match ranges survive re-casing")
    func matchingStateSurvives() {
        var item = SQLCompletionItem.keyword("SELECT")
        item.matchedRanges = [0..<3]
        item.fuzzyPenalty = 7
        let cased = applied([item], "sel")[0]
        #expect(cased.filterText == "select")
        #expect(cased.matchedRanges == [0..<3])
        #expect(cased.fuzzyPenalty == 7)
        #expect(cased.sortPriority == item.sortPriority)
        #expect(cased.kind == item.kind)
    }

    @Test("Re-casing an already re-cased item gives the same answer as re-casing the original")
    func foldingIsIdempotent() {
        let original = SQLCompletionItem.keyword("SELECT")
        let lowered = applied([original], "sel")[0]
        #expect(applied([lowered], "SEL")[0].insertText == "SELECT")
        #expect(applied([lowered], "sel")[0].insertText == "select")
    }

    /// A locale-sensitive fold turns `INSERT` into `ınsert` and `insert` into `İNSERT` under
    /// Turkish, and no SQL engine knows either spelling. The first expectation pins that the hazard
    /// is real rather than folklore; the rest pin that the transform does not take that path.
    @Test("Folding is locale-independent")
    func foldingIgnoresLocale() {
        let turkish = Locale(identifier: "tr_TR")
        #expect(("INSERT" as NSString).lowercased(with: turkish) == "ınsert")
        #expect(("insert" as NSString).uppercased(with: turkish) == "İNSERT")

        for keyword in ["INSERT", "LIMIT", "DISTINCT", "ILIKE"] {
            #expect(first(keyword, prefix: "a").insertText == keyword.lowercased())
            #expect(first(keyword, prefix: "A").insertText == keyword)
            #expect(SQLCompletionCasing.folded(keyword, uppercase: false) == keyword.lowercased())
            #expect(SQLCompletionCasing.folded(keyword.lowercased(), uppercase: true) == keyword)
        }
    }

    // MARK: - The policy's own vocabulary

    @Test("Only the absolute policies rewrite what the user typed")
    func rewritesTypedText() {
        #expect(SQLKeywordCase.upper.rewritesTypedText)
        #expect(SQLKeywordCase.lower.rewritesTypedText)
        #expect(!SQLKeywordCase.matchTypedElseUpper.rewritesTypedText)
        #expect(!SQLKeywordCase.matchTypedElseLower.rewritesTypedText)
    }

    @Test("Every policy names the case it falls back to")
    func prefersUppercase() {
        #expect(SQLKeywordCase.upper.prefersUppercase)
        #expect(SQLKeywordCase.matchTypedElseUpper.prefersUppercase)
        #expect(!SQLKeywordCase.lower.prefersUppercase)
        #expect(!SQLKeywordCase.matchTypedElseLower.prefersUppercase)
    }

    @Test("Every policy has a distinct, non-empty display name")
    func displayNames() {
        let names = SQLKeywordCase.allCases.map(\.displayName)
        #expect(Set(names).count == SQLKeywordCase.allCases.count)
        #expect(names.allSatisfy { !$0.isEmpty })
    }

    @Test("The default reproduces the shipped output when nothing has been typed")
    func defaultPolicy() {
        #expect(SQLKeywordCase.default == .matchTypedElseUpper)
        #expect(first("SELECT", prefix: "").insertText == "SELECT")
    }

    // MARK: - Through the engine, with a dialect

    private func dialect(
        functions: Set<String>,
        functionNamesAreCaseInsensitive: Bool,
        operators: [SQLOperatorDescriptor] = []
    ) -> SQLDialectDescriptor {
        SQLDialectDescriptor(
            identifierQuote: "\"",
            keywords: ["SELECT", "FROM", "WHERE"],
            functions: functions,
            dataTypes: [],
            operators: operators,
            textCastTypeName: nil,
            functionNamesAreCaseInsensitive: functionNamesAreCaseInsensitive
        )
    }

    private func inserted(_ text: String, dialect: SQLDialectDescriptor) async -> [String] {
        let engine = CompletionEngine(schemaProvider: nil, databaseType: nil, dialect: dialect)
        let context = await engine.getCompletions(
            text: text,
            cursorPosition: (text as NSString).length,
            keywordCase: .matchTypedElseUpper
        )
        return context?.items.map(\.insertText) ?? []
    }

    @Test("A dialect whose function names are case-insensitive follows the typed case")
    func caseInsensitiveDialectFunctionsFollowTheTypedCase() async {
        let descriptor = dialect(functions: ["STRING_AGG"], functionNamesAreCaseInsensitive: true)
        #expect(await inserted("SELECT string_a", dialect: descriptor).contains("string_agg()"))
        #expect(await inserted("SELECT STRING_A", dialect: descriptor).contains("STRING_AGG()"))
    }

    /// Measured on ClickHouse 26.9.1.52: `toString` and `uniq` are rejected as UNKNOWN_FUNCTION in
    /// any other case, so the dialect declares its function names case-sensitive and they are never
    /// folded, whichever case the prefix is in.
    @Test("A dialect whose function names are case-sensitive keeps every spelling")
    func caseSensitiveDialectFunctionsKeepTheirSpelling() async {
        let descriptor = dialect(functions: ["toString", "uniq"], functionNamesAreCaseInsensitive: false)
        #expect(await inserted("SELECT tos", dialect: descriptor).contains("toString()"))
        #expect(await inserted("SELECT TOS", dialect: descriptor).contains("toString()"))
        #expect(await inserted("SELECT uni", dialect: descriptor).contains("uniq()"))
        #expect(await inserted("SELECT UNI", dialect: descriptor).contains("uniq()"))
    }

    /// A dialect's operator list is not only symbols: PostgreSQL declares `IS DISTINCT FROM` and
    /// `IS NOT NULL` there, and the same words also arrive from the built-in keyword table.
    @Test("A word operator a dialect declares follows the typed case")
    func dialectWordOperatorsFollowTheTypedCase() async {
        let descriptor = dialect(
            functions: [],
            functionNamesAreCaseInsensitive: true,
            operators: [
                SQLOperatorDescriptor(symbol: "IS DISTINCT FROM", summary: "Not equal", category: .predicate),
                SQLOperatorDescriptor(symbol: "@>", summary: "Contains", category: .json)
            ]
        )
        let lowered = await inserted("SELECT * FROM t WHERE a is d", dialect: descriptor)
        #expect(lowered.contains("is distinct from"))
        #expect(!lowered.contains("IS DISTINCT FROM"))

        let raised = await inserted("SELECT * FROM t WHERE a IS D", dialect: descriptor)
        #expect(raised.contains("IS DISTINCT FROM"))
    }
}
