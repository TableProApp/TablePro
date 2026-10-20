import Foundation
@testable import TableProMobile
import TableProModels
import Testing

struct CompletionIdentifierQuotingTests {
    @Test("a name the engine reads as written stays bare", arguments: [
        ("Invoice", DatabaseType.sqlite),
        ("orders", .postgresql),
        ("orders", .redshift),
        ("OrderItems", .mysql),
        ("OrderItems", .mariadb),
        ("Orders", .mssql),
        ("ORDERS", .oracle),
        ("Orders", .duckdb),
    ])
    func bareNames(name: String, type: DatabaseType) {
        #expect(CompletionIdentifierQuoting.quoted(name, for: type) == name)
    }

    @Test("an engine that folds unquoted names quotes a name in any other case")
    func foldedCase() {
        #expect(CompletionIdentifierQuoting.quoted("Orders", for: .postgresql) == "\"Orders\"")
        #expect(CompletionIdentifierQuoting.quoted("InvoiceLine", for: .redshift) == "\"InvoiceLine\"")
        #expect(CompletionIdentifierQuoting.quoted("orders", for: .oracle) == "\"orders\"")
        #expect(CompletionIdentifierQuoting.quoted("Orders", for: .oracle) == "\"Orders\"")
        #expect(CompletionIdentifierQuoting.quoted("Orders", for: .mysql) == "Orders")
        #expect(CompletionIdentifierQuoting.quoted("Orders", for: .sqlite) == "Orders")
    }

    @Test("a reserved word is quoted with the engine's own quote")
    func reservedWord() {
        #expect(CompletionIdentifierQuoting.quoted("order", for: .postgresql) == "\"order\"")
        #expect(CompletionIdentifierQuoting.quoted("order", for: .mysql) == "`order`")
        #expect(CompletionIdentifierQuoting.quoted("order", for: .mssql) == "[order]")
        #expect(CompletionIdentifierQuoting.quoted("order", for: .sqlite) == "\"order\"")
        #expect(CompletionIdentifierQuoting.quoted("ORDER", for: .oracle) == "\"ORDER\"")
    }

    @Test("date reads as a keyword on every engine", arguments: [
        (DatabaseType.postgresql, "\"date\""),
        (.redshift, "\"date\""),
        (.mysql, "`date`"),
        (.mariadb, "`date`"),
        (.tidb, "`date`"),
        (.mssql, "[date]"),
        (.sqlite, "\"date\""),
        (.duckdb, "\"date\""),
        (.oracle, "\"date\""),
    ])
    func dateColumn(type: DatabaseType, expected: String) {
        #expect(CompletionIdentifierQuoting.quoted("date", for: type) == expected)
    }

    @Test("a word the engine reserves is quoted where the completion vocabulary lacks it", arguments: [
        ("user", DatabaseType.postgresql, "\"user\""),
        ("window", .redshift, "\"window\""),
        ("pivot", .duckdb, "\"pivot\""),
        ("dual", .mysql, "`dual`"),
        ("file", .mssql, "[file]"),
        ("SIZE", .oracle, "\"SIZE\""),
        ("pragma", .sqlite, "\"pragma\""),
    ])
    func engineReservedWord(name: String, type: DatabaseType, expected: String) {
        #expect(CompletionIdentifierQuoting.quoted(name, for: type) == expected)
    }

    @Test("a word only another engine reserves stays bare")
    func otherEngineReservedWord() {
        #expect(CompletionIdentifierQuoting.quoted("user", for: .mysql) == "user")
        #expect(CompletionIdentifierQuoting.quoted("size", for: .postgresql) == "size")
        #expect(CompletionIdentifierQuoting.quoted("pragma", for: .mssql) == "pragma")
    }

    @Test("a character outside the bare set or a leading digit needs quotes")
    func characters() {
        #expect(CompletionIdentifierQuoting.quoted("Order Details", for: .mssql) == "[Order Details]")
        #expect(CompletionIdentifierQuoting.quoted("order-items", for: .postgresql) == "\"order-items\"")
        #expect(CompletionIdentifierQuoting.quoted("2fa", for: .postgresql) == "\"2fa\"")
        #expect(CompletionIdentifierQuoting.quoted("2fa", for: .sqlite) == "\"2fa\"")
        #expect(CompletionIdentifierQuoting.quoted("2fa", for: .mysql) == "2fa")
        #expect(CompletionIdentifierQuoting.quoted("2024", for: .mysql) == "`2024`")
        #expect(CompletionIdentifierQuoting.quoted("1e3", for: .mysql) == "`1e3`")
        #expect(CompletionIdentifierQuoting.quoted("0x1F", for: .mariadb) == "`0x1F`")
        #expect(CompletionIdentifierQuoting.quoted("0b101", for: .mysql) == "`0b101`")
        #expect(CompletionIdentifierQuoting.quoted("_AUDIT", for: .oracle) == "\"_AUDIT\"")
    }

    @Test("each engine's extra identifier characters stay bare")
    func engineCharacters() {
        #expect(CompletionIdentifierQuoting.quoted("V$SESSION", for: .oracle) == "V$SESSION")
        #expect(CompletionIdentifierQuoting.quoted("LOG#1", for: .oracle) == "LOG#1")
        #expect(CompletionIdentifierQuoting.quoted("price$", for: .postgresql) == "price$")
        #expect(CompletionIdentifierQuoting.quoted("price$", for: .mysql) == "price$")
        #expect(CompletionIdentifierQuoting.quoted("audit#log", for: .mssql) == "audit#log")
        #expect(CompletionIdentifierQuoting.quoted("price$", for: .duckdb) == "\"price$\"")
        #expect(CompletionIdentifierQuoting.quoted("café", for: .postgresql) == "café")
        #expect(CompletionIdentifierQuoting.quoted("café", for: .mysql) == "café")
        #expect(CompletionIdentifierQuoting.quoted("CAFÉ", for: .oracle) == "\"CAFÉ\"")
    }

    @Test("the closing quote inside a name is doubled")
    func doubledClose() {
        #expect(CompletionIdentifierQuoting.quoted("say \"hi\"", for: .postgresql) == "\"say \"\"hi\"\"\"")
        #expect(CompletionIdentifierQuoting.quoted("a]b", for: .mssql) == "[a]]b]")
        #expect(CompletionIdentifierQuoting.quoted("a`b", for: .mysql) == "`a``b`")
    }

    @Test("a name read from the statement keeps the case it was written in")
    func asWritten() {
        #expect(CompletionIdentifierQuoting.quotedAsWritten("O", for: .postgresql) == "O")
        #expect(CompletionIdentifierQuoting.quotedAsWritten("o", for: .oracle) == "o")
        #expect(CompletionIdentifierQuoting.quotedAsWritten("order line", for: .postgresql) == "\"order line\"")
        #expect(CompletionIdentifierQuoting.quotedAsWritten("order line", for: .mssql) == "[order line]")
    }
}
