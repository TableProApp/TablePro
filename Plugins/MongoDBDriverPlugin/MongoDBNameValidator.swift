import Foundation
import TableProPluginKit

enum MongoDBNameValidationError: Error, Equatable {
    case emptyDatabaseName
    case databaseNameTooLong
    case databaseNameInvalidCharacter(Character)
    case emptyCollectionName
    case collectionNameInvalidCharacter(Character)
    case collectionNameReservedPrefix
    case namespaceTooLong
}

extension MongoDBNameValidationError: PluginDriverError {
    var pluginErrorMessage: String {
        switch self {
        case .emptyDatabaseName:
            return String(localized: "Enter a database name.")
        case .databaseNameTooLong:
            return String(
                format: String(localized: "A database name must be shorter than %ld bytes."),
                MongoDBNameValidator.maxDatabaseNameBytes
            )
        case .databaseNameInvalidCharacter(let character):
            return String(
                format: String(localized: "A database name cannot contain %@."),
                String(character)
            )
        case .emptyCollectionName:
            return String(localized: "Enter a collection name.")
        case .collectionNameInvalidCharacter(let character):
            return String(
                format: String(localized: "A collection name cannot contain %@."),
                String(character)
            )
        case .collectionNameReservedPrefix:
            return String(
                format: String(localized: "A collection name cannot start with %@."),
                MongoDBNameValidator.reservedCollectionPrefix
            )
        case .namespaceTooLong:
            return String(
                format: String(localized: "The database and collection names together must be %ld bytes or fewer."),
                MongoDBNameValidator.maxNamespaceBytes
            )
        }
    }
}

enum MongoDBNameValidator {
    static let maxDatabaseNameBytes = 64
    static let maxNamespaceBytes = 255
    static let reservedCollectionPrefix = "system."

    private static let forbiddenDatabaseCharacters: Set<Character> = ["/", "\\", ".", "\"", "$", "\0"]
    private static let forbiddenCollectionCharacters: Set<Character> = ["$", "\0"]

    static func validateDatabaseName(_ name: String) throws {
        guard !name.isEmpty else {
            throw MongoDBNameValidationError.emptyDatabaseName
        }
        if let offender = name.first(where: forbiddenDatabaseCharacters.contains) {
            throw MongoDBNameValidationError.databaseNameInvalidCharacter(offender)
        }
        guard name.utf8.count < maxDatabaseNameBytes else {
            throw MongoDBNameValidationError.databaseNameTooLong
        }
    }

    static func validateCollectionName(_ name: String, inDatabase database: String) throws {
        guard !name.isEmpty else {
            throw MongoDBNameValidationError.emptyCollectionName
        }
        if let offender = name.first(where: forbiddenCollectionCharacters.contains) {
            throw MongoDBNameValidationError.collectionNameInvalidCharacter(offender)
        }
        guard !name.hasPrefix(reservedCollectionPrefix) else {
            throw MongoDBNameValidationError.collectionNameReservedPrefix
        }
        guard database.utf8.count + 1 + name.utf8.count <= maxNamespaceBytes else {
            throw MongoDBNameValidationError.namespaceTooLong
        }
    }
}
