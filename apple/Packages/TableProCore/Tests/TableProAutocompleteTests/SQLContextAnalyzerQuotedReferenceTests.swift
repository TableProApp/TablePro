import Foundation
@testable import TableProAutocomplete
import TableProSQLGrammar
import Testing

struct SQLContextAnalyzerQuotedReferenceTests {
    private let analyzer = SQLContextAnalyzer()

    private func context(_ query: String, on engine: String, cursor: Int? = nil) -> SQLContext {
        analyzer.analyze(
            query: query,
            cursorPosition: cursor ?? (query as NSString).length,
            grammar: .engine(engine)
        )
    }

    private func cursor(after marker: String, in query: String) -> Int {
        let range = (query as NSString).range(of: marker)
        return range.location + range.length
    }

    @Test(
        "A quoted table name becomes a reference",
        arguments: [
            ("SELECT o. FROM [orders] o", "SQL Server", "orders", nil as String?),
            ("SELECT o. FROM [dbo].[orders] o", "SQL Server", "orders", "dbo"),
            ("SELECT o. FROM [orders] o", "SQLite", "orders", nil),
            ("SELECT o. FROM \"public\".\"orders\" o", "PostgreSQL", "orders", "public"),
            ("SELECT o. FROM \"ORDERS\" o", "Oracle", "ORDERS", nil),
            ("SELECT o. FROM public.orders o", "PostgreSQL", "orders", "public"),
            ("SELECT o. FROM orders o", "SQL Server", "orders", nil)
        ]
    )
    func quotedTableBecomesAReference(query: String, engine: String, table: String, schema: String?) {
        let result = context(query, on: engine, cursor: cursor(after: "o.", in: query))
        #expect(result.dotPrefix == "o")
        #expect(result.tableReferences.contains { $0.tableName == table && $0.alias == "o" && $0.schema == schema })
    }

    @Test("A reference records whether the name it goes by was quoted")
    func quotedIdentifierIsRecorded() {
        let query = "SELECT * FROM orders AS \"O\", \"Customers\", items i, sales.\"Audit\" a WHERE "
        let references = context(query, on: "PostgreSQL").tableReferences
        let quoted = Dictionary(references.map { ($0.identifier, $0.isIdentifierQuoted) }, uniquingKeysWith: { $0 || $1 })

        #expect(quoted["O"] == true)
        #expect(quoted["Customers"] == true)
        #expect(quoted["i"] == false)
        #expect(quoted["a"] == false)
    }

    // The shape the iOS SELECT * FROM template writes on SQL Server.
    @Test("A bracketed template query keeps its alias")
    func bracketedTemplateKeepsItsAlias() {
        let query = "SELECT * FROM [dbo].[orders] o WHERE o. ORDER BY (SELECT NULL) OFFSET 0 ROWS FETCH NEXT 100 ROWS ONLY"
        let result = context(query, on: "SQL Server", cursor: cursor(after: "WHERE o.", in: query))
        #expect(result.dotPrefix == "o")
        #expect(result.tableReferences.contains { $0.tableName == "orders" && $0.alias == "o" })
    }

    @Test("A bracketed join target becomes a reference")
    func bracketedJoinTarget() {
        let result = context("SELECT * FROM a JOIN [orders] o ON o.", on: "SQL Server")
        #expect(result.tableReferences.contains { $0.tableName == "a" })
        #expect(result.tableReferences.contains { $0.tableName == "orders" && $0.alias == "o" })
    }

    // `ORDER` inside the quoted name used to end the FROM list.
    @Test(
        "A name with a space or a keyword inside its quotes stays whole",
        arguments: [
            ("SELECT od. FROM \"Order Details\" od", "PostgreSQL", "Order Details", "od"),
            ("SELECT od. FROM `Order Details` od", "MySQL", "Order Details", "od"),
            ("SELECT li. FROM \"Line Items\" li", "PostgreSQL", "Line Items", "li"),
            ("SELECT od. FROM [Order Details] od", "SQL Server", "Order Details", "od")
        ]
    )
    func spacedNameStaysWhole(query: String, engine: String, table: String, alias: String) {
        let result = context(query, on: engine, cursor: cursor(after: "\(alias).", in: query))
        #expect(result.tableReferences.contains { $0.tableName == table && $0.alias == alias })
        #expect(!result.tableReferences.contains { $0.tableName == "Line" || $0.tableName == "Order" })
    }

    @Test("A doubled quote inside a name reads as one quote")
    func doubledQuoteInsideAName() {
        let query = "SELECT q. FROM \"say \"\"hi\"\"\" q"
        let result = context(query, on: "PostgreSQL", cursor: cursor(after: "q.", in: query))
        #expect(result.tableReferences.contains { $0.tableName == "say \"hi\"" && $0.alias == "q" })
    }

    @Test("Dollar and hash continue a bare name on Oracle")
    func dollarAndHashContinueANameOnOracle() {
        let query = "SELECT x. FROM SYS$T x"
        let result = context(query, on: "Oracle", cursor: cursor(after: "x.", in: query))
        #expect(result.tableReferences.contains { $0.tableName == "SYS$T" && $0.alias == "x" })
    }

    @Test("A quoted qualifier gives the dot prefix")
    func quotedQualifierGivesTheDotPrefix() {
        let bracketed = context("SELECT * FROM [dbo].[ord", on: "SQL Server")
        #expect(bracketed.dotPrefix == "dbo")
        #expect(bracketed.prefix == "ord")

        let quoted = context("SELECT * FROM \"my schema\".ord", on: "PostgreSQL")
        #expect(quoted.dotPrefix == "my schema")
        #expect(quoted.prefix == "ord")
    }

    @Test("A dot inside a quoted name is no qualifier")
    func dotInsideAQuotedName() {
        let query = "SELECT * FROM \"a.b\""
        let result = context(query, on: "PostgreSQL", cursor: 18)
        #expect(result.dotPrefix == nil)
    }

    @Test("An open bracket is part of the replaced token", arguments: ["SQL Server", "SQLite"])
    func openBracketIsReplaced(engine: String) {
        let result = context("SELECT * FROM [ord", on: engine)
        #expect(result.clauseType == .from)
        #expect(result.prefix == "ord")
        #expect(result.prefixRange == 14..<18)
    }

    @Test(
        "A closed pair replaces only the name between its quotes",
        arguments: [
            ("SELECT * FROM [ord]", "SQL Server"),
            ("SELECT * FROM \"ord\"", "PostgreSQL")
        ]
    )
    func closedPairReplacesTheName(query: String, engine: String) {
        let result = context(query, on: engine, cursor: 18)
        #expect(!result.isInsideString)
        #expect(result.clauseType == .from)
        #expect(result.expectsObjectName)
        #expect(result.prefix == "ord")
        #expect(result.prefixRange == 15..<18)
    }

    @Test("SET is never an UPDATE alias")
    func setIsNeverAnAlias() {
        let result = context("UPDATE orders SET to", on: "PostgreSQL")
        #expect(result.clauseType == .set)
        #expect(result.tableReferences.contains { $0.tableName == "orders" && $0.alias == nil })
        #expect(!result.tableReferences.contains { $0.alias == "SET" })
    }

    @Test("An UPDATE with a FROM list keeps both tables under their own names")
    func updateWithFromListKeepsBothTables() {
        let result = context("UPDATE orders SET total = c.x FROM customers c WHERE ", on: "PostgreSQL")
        #expect(result.tableReferences.contains { $0.tableName == "orders" && $0.alias == nil })
        #expect(result.tableReferences.contains { $0.tableName == "customers" && $0.alias == "c" })
        #expect(!result.tableReferences.contains { $0.identifier == "SET" })
    }

    @Test("An UPDATE alias still resolves")
    func updateAliasStillResolves() {
        let result = context("UPDATE orders o SET to", on: "PostgreSQL")
        #expect(result.tableReferences.contains { $0.tableName == "orders" && $0.alias == "o" })
    }
}
