import Foundation
@testable import TablePro
@testable import TableProAutocomplete
import Testing

struct SQLSchemaProviderNameIndexTests {
    private static func labels(_ index: SQLCompletionNameIndex?) -> [String]? {
        index.map { index in (0..<index.count).map { index.item(at: $0).label } }
    }

    @Test("the name index holds the tables a bare name reaches, as the items list them, and follows a new list")
    func indexFollowsTheTableList() async {
        let provider = SQLSchemaProvider()
        await provider.updateTables([
            TestFixtures.makeTableInfo(name: "orders"),
            TestFixtures.makeTableInfo(name: "v_sales", type: .view),
            TestFixtures.makeTableInfo(name: "Customers")
        ])

        let index = await provider.tableNameIndex()
        let items = await provider.tableCompletionItems()
        #expect(Self.labels(index) == items.map(\.label))
        #expect(index.map { index in (0..<index.count).map { index.item(at: $0).kind } } == items.map(\.kind))

        await provider.updateTables([TestFixtures.makeTableInfo(name: "invoices")])
        #expect(Self.labels(await provider.tableNameIndex()) == ["invoices"])
    }
}
