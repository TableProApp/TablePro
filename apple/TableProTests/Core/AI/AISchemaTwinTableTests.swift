import Foundation
@testable import TablePro
import Testing

struct AISchemaTwinTableTests {
    @Test("A ranking keeps both of two tables whose names differ only in Unicode form, each with its own columns")
    func rankingKeepsBothTwins() {
        let tables = [TwinNames.composed, TwinNames.decomposed, "orders", "customers"].map {
            TestFixtures.makeTableInfo(name: $0)
        }
        let columns: [CatalogName: [ColumnInfo]] = [
            CatalogName(TwinNames.composed): [TestFixtures.makeColumnInfo(name: "espresso")],
            CatalogName(TwinNames.decomposed): [TestFixtures.makeColumnInfo(name: "latte")],
            "orders": [TestFixtures.makeColumnInfo(name: "id")],
            "customers": [TestFixtures.makeColumnInfo(name: "id")]
        ]

        let ranked = AISchemaContext.relevantTableNames(
            in: tables, columnsByTable: columns, question: "espresso latte", maxTables: 1
        )

        #expect(Set(ranked.map { CatalogName($0) }).isSuperset(of: [CatalogName(TwinNames.composed), CatalogName(TwinNames.decomposed)]))
        #expect(ranked.count == Set(ranked.map { CatalogName($0) }).count)
    }
}
