import Foundation
@testable import TablePro
import Testing

@Suite("QueryTabManager.tabTitle")
@MainActor
struct QueryTabManagerTabTitleTests {
    @Test("Returns plain name when schema is nil")
    func nilSchemaReturnsName() {
        let title = QueryTabManager.tabTitle(name: "users", schema: nil, databaseType: .postgresql)
        #expect(title == "users")
    }

    @Test("Returns plain name when schema is empty string")
    func emptySchemaReturnsName() {
        let title = QueryTabManager.tabTitle(name: "users", schema: "", databaseType: .postgresql)
        #expect(title == "users")
    }

    @Test("Returns plain name when schema matches the database default")
    func defaultSchemaReturnsName() {
        let title = QueryTabManager.tabTitle(name: "users", schema: "public", databaseType: .postgresql)
        #expect(title == "users")
    }

    @Test("Qualifies with schema when schema differs from default")
    func nonDefaultSchemaQualifies() {
        let title = QueryTabManager.tabTitle(name: "audit_log_entries", schema: "auth", databaseType: .postgresql)
        #expect(title == "auth.audit_log_entries")
    }

    @Test("MSSQL default schema is dbo")
    func mssqlDboReturnsName() {
        let title = QueryTabManager.tabTitle(name: "Orders", schema: "dbo", databaseType: .mssql)
        #expect(title == "Orders")
    }

    @Test("MSSQL non-default schema qualifies")
    func mssqlNonDboQualifies() {
        let title = QueryTabManager.tabTitle(name: "Customers", schema: "sales", databaseType: .mssql)
        #expect(title == "sales.Customers")
    }
}
