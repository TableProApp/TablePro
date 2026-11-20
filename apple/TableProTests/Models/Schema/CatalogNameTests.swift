import Foundation
@testable import TablePro
import Testing

enum TwinNames {
    static let composed = "caf\u{E9}"
    static let decomposed = "cafe\u{301}"
}

struct CatalogNameTests {
    @Test("Two spellings Swift's String equates are two catalog names")
    func twinsAreTwoNames() {
        #expect(TwinNames.composed == TwinNames.decomposed)
        #expect(CatalogName(TwinNames.composed) != CatalogName(TwinNames.decomposed))
        #expect(Set([CatalogName(TwinNames.composed), CatalogName(TwinNames.decomposed)]).count == 2)
        #expect(CatalogName("orders") == "orders")
    }

    @Test("A joined key stays apart for twins, keeps an ASCII name as it is, and reads back")
    func exactKeyRoundTrips() {
        let composed = CatalogName(TwinNames.composed)
        let decomposed = CatalogName(TwinNames.decomposed)

        #expect(composed.exactKey != decomposed.exactKey)
        #expect(CatalogName("orders").exactKey == "orders")
        #expect(CatalogName(exactKey: decomposed.exactKey) == decomposed)
        #expect(CatalogName(exactKey: "orders") == nil)
    }

    @Test("Two twin tables are two table infos, and two twin schemas two scope keys")
    func tablesAndScopesKeepTwinsApart() {
        let tables = Set([
            TestFixtures.makeTableInfo(name: TwinNames.composed),
            TestFixtures.makeTableInfo(name: TwinNames.decomposed)
        ])
        let id = UUID()
        let composed = DatabaseScope(connectionId: id, database: "shop", schema: TwinNames.composed)
        let decomposed = DatabaseScope(connectionId: id, database: "shop", schema: TwinNames.decomposed)

        #expect(tables.count == 2)
        #expect(composed.catalogKey != decomposed.catalogKey)
        #expect(composed.catalogKey == DatabaseScope(connectionId: id, database: "shop", schema: TwinNames.composed).catalogKey)
    }
}
