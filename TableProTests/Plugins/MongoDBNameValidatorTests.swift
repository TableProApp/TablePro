import Foundation
@testable import TablePro
import Testing

@Suite("MongoDBNameValidator")
struct MongoDBNameValidatorTests {
    @Test("A plain database name passes")
    func testValidDatabaseName() throws {
        try MongoDBNameValidator.validateDatabaseName("shop")
    }

    @Test("An empty database name is rejected")
    func testEmptyDatabaseName() {
        #expect(throws: MongoDBNameValidationError.emptyDatabaseName) {
            try MongoDBNameValidator.validateDatabaseName("")
        }
    }

    @Test("Each character MongoDB forbids in a database name is rejected", arguments: ["/", "\\", ".", "\"", "$"])
    func testForbiddenDatabaseCharacters(character: String) {
        #expect(throws: MongoDBNameValidationError.databaseNameInvalidCharacter(Character(character))) {
            try MongoDBNameValidator.validateDatabaseName("sh\(character)op")
        }
    }

    @Test("A database name of 64 bytes or more is rejected")
    func testDatabaseNameLength() throws {
        try MongoDBNameValidator.validateDatabaseName(String(repeating: "a", count: 63))
        #expect(throws: MongoDBNameValidationError.databaseNameTooLong) {
            try MongoDBNameValidator.validateDatabaseName(String(repeating: "a", count: 64))
        }
    }

    @Test("Database name length counts bytes, not characters")
    func testDatabaseNameCountsBytes() {
        #expect(throws: MongoDBNameValidationError.databaseNameTooLong) {
            try MongoDBNameValidator.validateDatabaseName(String(repeating: "é", count: 32))
        }
    }

    @Test("A plain collection name passes")
    func testValidCollectionName() throws {
        try MongoDBNameValidator.validateCollectionName("orders", inDatabase: "shop")
    }

    @Test("An empty collection name is rejected")
    func testEmptyCollectionName() {
        #expect(throws: MongoDBNameValidationError.emptyCollectionName) {
            try MongoDBNameValidator.validateCollectionName("", inDatabase: "shop")
        }
    }

    @Test("A collection name containing a dollar sign is rejected")
    func testCollectionNameDollarSign() {
        #expect(throws: MongoDBNameValidationError.collectionNameInvalidCharacter("$")) {
            try MongoDBNameValidator.validateCollectionName("or$ders", inDatabase: "shop")
        }
    }

    @Test("A collection name in the system namespace is rejected")
    func testCollectionNameReservedPrefix() {
        #expect(throws: MongoDBNameValidationError.collectionNameReservedPrefix) {
            try MongoDBNameValidator.validateCollectionName("system.users", inDatabase: "shop")
        }
    }

    @Test("A dot inside a collection name is allowed")
    func testCollectionNameDotIsAllowed() throws {
        try MongoDBNameValidator.validateCollectionName("orders.archive", inDatabase: "shop")
    }

    @Test("A namespace longer than 255 bytes is rejected")
    func testNamespaceLength() throws {
        let database = String(repeating: "a", count: 63)
        try MongoDBNameValidator.validateCollectionName(String(repeating: "b", count: 191), inDatabase: database)
        #expect(throws: MongoDBNameValidationError.namespaceTooLong) {
            try MongoDBNameValidator.validateCollectionName(String(repeating: "b", count: 192), inDatabase: database)
        }
    }
}
