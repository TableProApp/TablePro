import Foundation
@testable import TablePro
import TableProPluginKit
import Testing

@Suite("MongoDBCreateDatabasePlan")
struct MongoDBCreateDatabasePlanTests {
    @Test("The typed collection name is used")
    func testUsesTypedName() {
        let name = MongoDBCreateDatabasePlan.firstCollectionName(
            from: [MongoDBCreateDatabasePlan.firstCollectionFieldId: "orders"],
            databaseName: "shop"
        )
        #expect(name == "orders")
    }

    @Test("Surrounding whitespace is trimmed")
    func testTrimsWhitespace() {
        let name = MongoDBCreateDatabasePlan.firstCollectionName(
            from: [MongoDBCreateDatabasePlan.firstCollectionFieldId: "  orders\n"],
            databaseName: "shop"
        )
        #expect(name == "orders")
    }

    @Test("A blank collection name falls back to the database name")
    func testBlankFallsBack() {
        let name = MongoDBCreateDatabasePlan.firstCollectionName(
            from: [MongoDBCreateDatabasePlan.firstCollectionFieldId: "   "],
            databaseName: "shop"
        )
        #expect(name == "shop")
    }

    @Test("An app that does not send the field still creates a collection")
    func testMissingFieldFallsBack() {
        let name = MongoDBCreateDatabasePlan.firstCollectionName(from: [:], databaseName: "shop")
        #expect(name == "shop")
    }

    @Test("The legacy form spec initializer declares no text inputs")
    func testLegacySpecHasNoTextInputs() {
        let spec = PluginCreateDatabaseFormSpec(fields: [])
        #expect(spec.textInputs.isEmpty)
    }
}
