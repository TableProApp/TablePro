@testable import TableProMobile
import TableProModels
import Testing

struct TableBrowserIdentityTests {
    private static let orders = TableInfo(name: "orders", type: .table)

    @Test("A database switch that keeps the selected table rebuilds the browser")
    func databaseSwitchChangesIdentity() {
        #expect(TableBrowserIdentity(Self.orders, "shop") != TableBrowserIdentity(Self.orders, "archive"))
    }

    @Test("The same table in the same database keeps the browser")
    func sameTableAndDatabaseKeepIdentity() {
        let reloaded = TableInfo(name: "orders", type: .table)
        #expect(TableBrowserIdentity(Self.orders, "shop") == TableBrowserIdentity(reloaded, "shop"))
    }

    @Test("Another table in the same database rebuilds the browser")
    func otherTableChangesIdentity() {
        let customers = TableInfo(name: "customers", type: .table)
        #expect(TableBrowserIdentity(Self.orders, "shop") != TableBrowserIdentity(customers, "shop"))
    }

    @Test("Selecting a table after none rebuilds the browser")
    func firstSelectionChangesIdentity() {
        #expect(TableBrowserIdentity(nil, "shop") != TableBrowserIdentity(Self.orders, "shop"))
    }
}
