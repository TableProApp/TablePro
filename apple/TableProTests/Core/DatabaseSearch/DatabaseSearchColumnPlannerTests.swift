import Foundation
import TableProPluginKit
import Testing

@testable import TablePro

struct DatabaseSearchColumnPlannerTests {
    private typealias Column = DatabaseSearchColumnPlanner.Column
    private typealias Engine = DatabaseSearchColumnPlanner.Engine

    private static let postgres = Engine(family: .postgres, castsToText: true)

    private static let columns: [Column] = [
        Column(name: "email", type: .text(rawType: "varchar(255)")),
        Column(name: "notes", type: .text(rawType: "TEXT")),
        Column(name: "id", type: .integer(rawType: "bigint")),
        Column(name: "price", type: .decimal(rawType: "numeric(10,2)")),
        Column(name: "born", type: .date(rawType: "date")),
        Column(name: "created_at", type: .timestamp(rawType: "timestamp")),
        Column(name: "opens_at", type: .date(rawType: "time")),
        Column(name: "token", type: .text(rawType: "uuid")),
        Column(name: "avatar", type: .blob(rawType: "bytea")),
        Column(name: "active", type: .boolean(rawType: "boolean")),
        Column(name: "profile", type: .json(rawType: "jsonb")),
        Column(name: "address", type: .text(rawType: "inet")),
        Column(name: "body", type: .text(rawType: "CLOB")),
        Column(name: "doc", type: .text(rawType: "xml")),
        Column(name: "tags", type: .array(rawType: "text[]", element: .text(rawType: "text"))),
        Column(name: "embedding", type: .vector(rawType: "vector(3)"))
    ]

    private func searched(_ term: String, _ configure: (inout DatabaseSearchOptions) -> Void = { _ in }) -> [String: TableFilter] {
        var options = DatabaseSearchOptions(term: term)
        configure(&options)
        let filters = DatabaseSearchColumnPlanner.filters(for: Self.columns, options: options, engine: Self.postgres)
        return Dictionary(uniqueKeysWithValues: filters.map { ($0.columnName, $0) })
    }

    @Test("A word searches text columns only, with the match mode and case flag")
    func wordSearchesTextColumns() {
        let filters = searched("ada@example.com")
        #expect(Set(filters.keys) == ["email", "notes", "profile", "body"])
        #expect(filters["email"]?.filterOperator == .contains)
        #expect(filters["email"]?.isCaseSensitive == false)
        #expect(filters["email"]?.value == "ada@example.com")
    }

    @Test("A number joins integer and decimal columns as an exact comparison")
    func numberJoinsNumericColumns() {
        let filters = searched("42")
        #expect(filters["id"]?.filterOperator == .equal)
        #expect(filters["price"]?.filterOperator == .equal)
        #expect(filters["email"]?.filterOperator == .contains)
        #expect(filters["born"] == nil)
    }

    @Test("A fraction joins decimal columns but not integer ones")
    func fractionSkipsIntegers() {
        let filters = searched("4.25")
        #expect(filters["price"] != nil)
        #expect(filters["id"] == nil)
    }

    @Test("A date joins date columns, a date and time joins timestamp columns")
    func datesJoinTheirColumns() {
        let date = searched("2024-02-29")
        #expect(date["born"]?.filterOperator == .equal)
        #expect(date["created_at"] == nil)
        #expect(date["opens_at"] == nil)

        let moment = searched("2024-02-29 13:45:10.123")
        #expect(moment["created_at"]?.filterOperator == .equal)
        #expect(moment["born"] == nil)

        #expect(searched("2023-02-29")["born"] == nil)
        #expect(searched("2024-02-29 24:00:00")["created_at"] == nil)
        #expect(searched("2024-02-29 13:45")["created_at"] == nil)
        #expect(searched("2024-02-29T13:45:10")["created_at"]?.filterOperator == .equal)
    }

    @Test("A UUID joins UUID columns, anything else leaves them out")
    func uuidJoinsUUIDColumns() {
        let filters = searched("6F9619FF-8B86-D011-B42D-00C04FC964FF")
        #expect(filters["token"]?.filterOperator == .equal)
        #expect(searched("6F9619FF")["token"] == nil)
    }

    @Test("Binary columns join only when ticked, and never for an exact match")
    func binaryNeedsTheOption() {
        #expect(searched("abc")["avatar"] == nil)
        #expect(searched("abc") { $0.includesBinaryColumns = true }["avatar"]?.filterOperator == .contains)
        let exact = searched("abc") {
            $0.includesBinaryColumns = true
            $0.matchMode = .exact
        }
        #expect(exact["avatar"] == nil)
    }

    @Test("An exact match skips types with no equality and non-character text")
    func exactSkipsTypesWithoutEquality() {
        let filters = searched("hello") { $0.matchMode = .exact }
        #expect(Set(filters.keys) == ["email", "notes"])
        #expect(filters["email"]?.filterOperator == .equal)
    }

    @Test("Starts with and case sensitivity reach every text filter")
    func modeAndCaseReachTextFilters() {
        let filters = searched("Ada") {
            $0.matchMode = .startsWith
            $0.isCaseSensitive = true
        }
        #expect(filters["email"]?.filterOperator == .startsWith)
        #expect(filters["email"]?.isCaseSensitive == true)
    }

    @Test("Boolean, array, vector and XML columns are never searched")
    func unsearchableTypesStayOut() {
        let filters = searched("true")
        #expect(filters["active"] == nil)
        #expect(filters["tags"] == nil)
        #expect(filters["doc"] == nil)
        #expect(searched("[1,2,3]")["embedding"] == nil)
    }

    @Test("A blank term searches nothing, and surrounding whitespace is dropped")
    func blankAndPaddedTerms() {
        #expect(searched("   ").isEmpty)
        #expect(searched("  ada\n")["email"]?.value == "ada")
    }

    @Test("ClickHouse's Nullable(String) counts as character text for an exact match")
    func wrappedStringIsCharacterText() {
        var options = DatabaseSearchOptions(term: "ada")
        options.matchMode = .exact
        let filters = DatabaseSearchColumnPlanner.filters(
            for: [Column(name: "name", type: .text(rawType: "Nullable(String)"))],
            options: options,
            engine: Engine(family: .clickhouse, castsToText: true)
        )
        #expect(filters.map(\.columnName) == ["name"])
    }

    @Test("An exact match skips SQL Server's legacy TEXT, which has no equality, and keeps TEXT elsewhere")
    func exactSkipsSQLServerText() {
        var options = DatabaseSearchOptions(term: "hello")
        options.matchMode = .exact
        let notes = [Column(name: "notes", type: .text(rawType: "text"))]
        #expect(DatabaseSearchColumnPlanner.filters(for: notes, options: options, engine: Engine(family: .mssql, castsToText: false)).isEmpty)
        #expect(DatabaseSearchColumnPlanner.filters(for: notes, options: options, engine: Self.postgres).count == 1)
        options.matchMode = .contains
        #expect(DatabaseSearchColumnPlanner.filters(for: notes, options: options, engine: Engine(family: .mssql, castsToText: false)).count == 1)
    }

    @Test("An engine that cannot read every column as text searches only its character columns")
    func strictEngineSearchesCharacterColumnsOnly() {
        let trino = Engine(family: .generic, castsToText: false)
        var options = DatabaseSearchOptions(term: "ada")
        options.includesBinaryColumns = true
        let words = DatabaseSearchColumnPlanner.filters(for: Self.columns, options: options, engine: trino)
        #expect(Set(words.map(\.columnName)) == ["email", "notes", "body"])

        let oracle = Engine(family: .oracle, castsToText: false)
        let oracleWords = DatabaseSearchColumnPlanner.filters(for: Self.columns, options: options, engine: oracle)
        #expect(Set(oracleWords.map(\.columnName)) == ["email", "notes", "body"])

        let mysql = Engine(family: .mysql, castsToText: false)
        let mysqlWords = DatabaseSearchColumnPlanner.filters(for: Self.columns, options: options, engine: mysql)
        #expect(Set(mysqlWords.map(\.columnName)) == ["email", "notes", "profile", "body", "avatar"])
    }

    @Test("An engine without a type family gets no quoted date or UUID comparison")
    func genericEngineSkipsTypedLiterals() {
        let trino = Engine(family: .generic, castsToText: false)
        let date = DatabaseSearchColumnPlanner.filters(for: Self.columns, options: DatabaseSearchOptions(term: "2024-02-29"), engine: trino)
        #expect(date.map(\.columnName).contains("born") == false)
        let uuid = DatabaseSearchColumnPlanner.filters(
            for: Self.columns, options: DatabaseSearchOptions(term: "6F9619FF-8B86-D011-B42D-00C04FC964FF"), engine: trino
        )
        #expect(uuid.map(\.columnName).contains("token") == false)
        let number = DatabaseSearchColumnPlanner.filters(for: Self.columns, options: DatabaseSearchOptions(term: "42"), engine: trino)
        #expect(number.map(\.columnName).contains("id"))
    }

    @Test("An exact match on a SET takes a list of declared labels")
    func exactSetTakesALabelList() {
        let colors = Column(name: "colors", type: .set(rawType: "set", values: ["red", "green", "blue"]))
        var options = DatabaseSearchOptions(term: "red,blue")
        options.matchMode = .exact
        #expect(DatabaseSearchColumnPlanner.filters(for: [colors], options: options, engine: Self.postgres).count == 1)
        options.term = "red,pink"
        #expect(DatabaseSearchColumnPlanner.filters(for: [colors], options: options, engine: Self.postgres).isEmpty)
    }

    @Test("An exact match on an enum needs a declared label")
    func exactEnumNeedsALabel() {
        let status = Column(name: "status", type: .enumType(rawType: "enum", values: ["open", "closed"]))
        var options = DatabaseSearchOptions(term: "OPEN")
        options.matchMode = .exact
        #expect(DatabaseSearchColumnPlanner.filters(for: [status], options: options, engine: Self.postgres).count == 1)
        options.isCaseSensitive = true
        #expect(DatabaseSearchColumnPlanner.filters(for: [status], options: options, engine: Self.postgres).isEmpty)
        options.term = "pending"
        options.isCaseSensitive = false
        #expect(DatabaseSearchColumnPlanner.filters(for: [status], options: options, engine: Self.postgres).isEmpty)
    }
}
