import Foundation
import TableProPluginKit
import Testing

@testable import TablePro

@Suite("ForeignKeyLookupQuery")
struct ForeignKeyLookupQueryTests {
    private let key = ForeignKeyLookupColumn(name: "ArtistId", type: .integer(rawType: "INTEGER"))
    private let label = ForeignKeyLookupColumn(name: "Name", type: .text(rawType: "NVARCHAR(120)"))

    private func dialect(
        paginationStyle: SQLDialectDescriptor.PaginationStyle = .limit,
        caseSensitivityStyle: SQLDialectDescriptor.CaseSensitivityStyle = .collationDefined,
        likeEscapeStyle: SQLDialectDescriptor.LikeEscapeStyle = .explicit
    ) -> SQLDialectDescriptor {
        SQLDialectDescriptor(
            identifierQuote: "\"",
            keywords: [],
            functions: [],
            dataTypes: [],
            likeEscapeStyle: likeEscapeStyle,
            paginationStyle: paginationStyle,
            caseSensitivityStyle: caseSensitivityStyle
        )
    }

    private func quote(_ name: String) -> String {
        "\"\(name)\""
    }

    private func rows(
        key: ForeignKeyLookupColumn? = nil,
        label: ForeignKeyLookupColumn?,
        term: String,
        dialect: SQLDialectDescriptor? = nil
    ) -> String? {
        ForeignKeyLookupQuery.rows(
            quotedTable: "\"Artist\"",
            key: key ?? self.key,
            label: label,
            searchTerm: term,
            dialect: dialect ?? self.dialect(),
            quoteIdentifier: quote
        )
    }

    @Test("An empty term lists the first rows in key order")
    func emptyTermListsTheFirstRows() {
        #expect(
            rows(label: label, term: "") ==
                "SELECT \"ArtistId\", \"Name\" FROM \"Artist\" WHERE \"ArtistId\" IS NOT NULL "
                + "ORDER BY \"ArtistId\" LIMIT 50"
        )
    }

    @Test("Whitespace is not a search term")
    func whitespaceIsNotATerm() {
        #expect(rows(label: label, term: "   ") == rows(label: label, term: ""))
    }

    /// T-SQL and Oracle parse OFFSET/FETCH as part of ORDER BY, and the key column supplies the
    /// order here, so the dialect's filler ORDER BY is neither needed nor emitted.
    @Test("An OFFSET/FETCH dialect orders by the key rather than by the dialect's filler")
    func offsetFetchOrdersByTheKey() {
        let sql = rows(label: label, term: "", dialect: dialect(paginationStyle: .offsetFetch))
        #expect(
            sql == "SELECT \"ArtistId\", \"Name\" FROM \"Artist\" WHERE \"ArtistId\" IS NOT NULL "
                + "ORDER BY \"ArtistId\" OFFSET 0 ROWS FETCH NEXT 50 ROWS ONLY"
        )
    }

    @Test("A table with no label column selects the key alone")
    func noLabelSelectsTheKeyAlone() {
        #expect(
            rows(label: nil, term: "") ==
                "SELECT \"ArtistId\" FROM \"Artist\" WHERE \"ArtistId\" IS NOT NULL "
                + "ORDER BY \"ArtistId\" LIMIT 50"
        )
    }

    @Test("A label that is the key is not selected twice")
    func labelEqualToTheKeyIsSelectedOnce() {
        #expect(
            rows(label: key, term: "") ==
                "SELECT \"ArtistId\" FROM \"Artist\" WHERE \"ArtistId\" IS NOT NULL "
                + "ORDER BY \"ArtistId\" LIMIT 50"
        )
    }

    @Test("A numeric term matches the key exactly and the label loosely")
    func numericTermMatchesBothColumns() {
        #expect(
            rows(label: label, term: "42") ==
                "SELECT \"ArtistId\", \"Name\" FROM \"Artist\" "
                + "WHERE \"ArtistId\" IS NOT NULL "
                + "AND (\"Name\" LIKE '%42%' ESCAPE '!' OR \"ArtistId\" = 42) "
                + "ORDER BY \"ArtistId\" LIMIT 50"
        )
    }

    /// `FilterSQLGenerator` quotes a term it cannot read as a number, and `ArtistId = 'rock'` is
    /// `operator does not exist: integer = text` on PostgreSQL rather than a query returning
    /// nothing. A word therefore reaches the label column alone.
    @Test("A word never reaches a numeric key column")
    func wordSkipsTheNumericKey() {
        #expect(
            rows(label: label, term: "rock") ==
                "SELECT \"ArtistId\", \"Name\" FROM \"Artist\" "
                + "WHERE \"ArtistId\" IS NOT NULL AND \"Name\" LIKE '%rock%' ESCAPE '!' "
                + "ORDER BY \"ArtistId\" LIMIT 50"
        )
    }

    @Test("A text key takes a substring match of its own")
    func textKeyTakesASubstringMatch() {
        let textKey = ForeignKeyLookupColumn(name: "Code", type: .text(rawType: "VARCHAR(8)"))
        #expect(
            rows(key: textKey, label: label, term: "rock") ==
                "SELECT \"Code\", \"Name\" FROM \"Artist\" "
                + "WHERE \"Code\" IS NOT NULL "
                + "AND (\"Name\" LIKE '%rock%' ESCAPE '!' OR \"Code\" LIKE '%rock%' ESCAPE '!') "
                + "ORDER BY \"Code\" LIMIT 50"
        )
    }

    /// A `LIKE` against a date column is a type error on a strict engine, so a label the user chose
    /// that is not text is shown beside the key and never searched.
    @Test("A label column that is not text carries no predicate")
    func nonTextLabelIsNotSearched() {
        let dateLabel = ForeignKeyLookupColumn(name: "ReleasedOn", type: .date(rawType: "DATE"))
        #expect(
            rows(label: dateLabel, term: "42") ==
                "SELECT \"ArtistId\", \"ReleasedOn\" FROM \"Artist\" "
                + "WHERE \"ArtistId\" IS NOT NULL AND \"ArtistId\" = 42 "
                + "ORDER BY \"ArtistId\" LIMIT 50"
        )
    }

    /// Nil rather than a query with no predicate: an unsearchable term means no matches, and
    /// listing the whole table instead would answer a question the user did not ask.
    @Test("A term no column can carry produces no query at all")
    func unsearchableTermProducesNoQuery() {
        let dateLabel = ForeignKeyLookupColumn(name: "ReleasedOn", type: .date(rawType: "DATE"))
        #expect(rows(label: dateLabel, term: "rock") == nil)
        #expect(rows(label: nil, term: "rock") == nil)
    }

    /// `ColumnTypeClassifier` files `UUID` under `.text`, and PostgreSQL has no `~~` for `uuid`, so
    /// a pattern predicate there turned every search on a UUID key into an error.
    @Test("A UUID key takes equality, never LIKE")
    func uuidKeyTakesEquality() {
        let uuidKey = ForeignKeyLookupColumn(name: "id", type: .text(rawType: "uuid"))
        let value = "2f9d0e6c-1a4b-4c3d-9e8f-0a1b2c3d4e5f"
        let sql = rows(key: uuidKey, label: nil, term: value)
        #expect(sql?.contains("\"id\" = '\(value)'") == true)
        #expect(sql?.contains("LIKE") == false)
    }

    @Test("A term that is not a UUID never reaches a UUID key")
    func malformedUuidSkipsTheKey() {
        let uuidKey = ForeignKeyLookupColumn(name: "id", type: .text(rawType: "uuid"))
        #expect(rows(key: uuidKey, label: nil, term: "2f9d") == nil)
        let withLabel = rows(key: uuidKey, label: label, term: "2f9d")
        #expect(withLabel?.contains("\"Name\" LIKE '%2f9d%'") == true)
        #expect(withLabel?.contains("\"id\" =") == false)
        #expect(withLabel?.contains("\"id\" LIKE") == false)
    }

    /// The classifier files every type it does not recognise under `.text`, so the question is
    /// asked of the raw type name and answered closed.
    @Test("A type the classifier only guessed at carries no pattern predicate")
    func unknownTextTypeIsNotPatternMatched() {
        let inetKey = ForeignKeyLookupColumn(name: "addr", type: .text(rawType: "inet"))
        #expect(rows(key: inetKey, label: nil, term: "10.0") == nil)
    }

    @Test("An enum or an array label is shown but never searched")
    func enumLabelIsNotSearched() {
        let enumLabel = ForeignKeyLookupColumn(name: "status", type: .enumType(rawType: "status_t", values: nil))
        #expect(rows(label: enumLabel, term: "rock") == nil)
        #expect(rows(label: enumLabel, term: "42")?.contains("\"status\" LIKE") == false)
    }

    @Test("A PostgreSQL dialect searches with ILIKE")
    func ilikeDialectUsesILike() {
        let sql = rows(label: label, term: "rock", dialect: dialect(caseSensitivityStyle: .ilikeOperator))
        #expect(sql?.contains("\"Name\" ILIKE '%rock%' ESCAPE '!'") == true)
    }

    @Test("A quote in the term is escaped rather than closing the literal")
    func quoteInTermIsEscaped() {
        let sql = rows(label: label, term: "O'Brien")
        #expect(sql?.contains("LIKE '%O''Brien%'") == true)
    }

    @Test("A wildcard in the term is matched literally")
    func wildcardInTermIsEscaped() {
        let sql = rows(label: label, term: "50%")
        #expect(sql?.contains("LIKE '%50!%%' ESCAPE '!'") == true)
    }

    @Test("MySQL escapes a wildcard with its own backslash convention")
    func mysqlWildcardEscaping() {
        let sql = rows(label: label, term: "50%", dialect: dialect(likeEscapeStyle: .implicit))
        #expect(sql?.contains("LIKE '%50\\\\%%'") == true)
        #expect(sql?.contains("ESCAPE") == false)
    }
}
