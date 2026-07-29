//
//  SQLFavoriteEditValidation.swift
//  TablePro
//

import Foundation
import Observation

internal enum SQLFavoriteKeywordValidation: Equatable {
    case valid
    case error(String)
    case warning(String)

    var blocksSave: Bool {
        if case .error = self { return true }
        return false
    }

    var isWarning: Bool {
        if case .warning = self { return true }
        return false
    }

    var displayText: String? {
        switch self {
        case .valid:
            return nil
        case let .error(text), let .warning(text):
            return text
        }
    }
}

internal enum SQLFavoriteKeywordValidator {
    static let reservedSQLKeywords: Set<String> = [
        "select", "from", "where", "insert", "update", "delete",
        "create", "drop", "alter", "join", "on", "and", "or",
        "not", "in", "like", "between", "order", "group", "having",
        "limit", "set", "values", "into", "as", "is", "null",
        "true", "false", "case", "when", "then", "else", "end"
    ]

    static func requiresAvailabilityCheck(_ trimmedKeyword: String) -> Bool {
        !trimmedKeyword.isEmpty && !trimmedKeyword.contains(" ")
    }

    static func classify(trimmedKeyword: String, isAvailable: Bool) -> SQLFavoriteKeywordValidation {
        guard !trimmedKeyword.isEmpty else { return .valid }
        guard !trimmedKeyword.contains(" ") else {
            return .error(String(localized: "Keyword cannot contain spaces"))
        }
        guard isAvailable else {
            return .error(String(localized: "This keyword is already in use"))
        }
        guard !reservedSQLKeywords.contains(trimmedKeyword.lowercased()) else {
            return .warning(String(
                format: String(localized: "Shadows the SQL keyword '%@'"),
                trimmedKeyword.uppercased()
            ))
        }
        return .valid
    }
}

@MainActor
@Observable
internal final class SQLFavoriteKeywordField {
    var keyword = ""
    private(set) var validation: SQLFavoriteKeywordValidation = .valid

    private var validationId = 0
    private let availabilityCheck: (String, UUID?, UUID?) async -> Bool

    init(
        availabilityCheck: @escaping (String, UUID?, UUID?) async -> Bool = { keyword, connectionId, excludingFavoriteId in
            await SQLFavoriteManager.shared.isKeywordAvailable(
                keyword,
                connectionId: connectionId,
                excludingFavoriteId: excludingFavoriteId
            )
        }
    ) {
        self.availabilityCheck = availabilityCheck
    }

    var trimmedKeyword: String {
        keyword.trimmingCharacters(in: .whitespaces)
    }

    func validate(connectionId: UUID?, excludingFavoriteId: UUID?) async {
        validationId += 1
        let currentId = validationId
        let trimmed = trimmedKeyword
        guard SQLFavoriteKeywordValidator.requiresAvailabilityCheck(trimmed) else {
            validation = SQLFavoriteKeywordValidator.classify(trimmedKeyword: trimmed, isAvailable: true)
            return
        }
        let available = await availabilityCheck(trimmed, connectionId, excludingFavoriteId)
        guard currentId == validationId else { return }
        validation = SQLFavoriteKeywordValidator.classify(trimmedKeyword: trimmed, isAvailable: available)
    }
}

internal enum SQLFavoriteEditValidation {
    static func canSave(
        isNameBlank: Bool,
        isQueryBlank: Bool = false,
        keywordValidation: SQLFavoriteKeywordValidation
    ) -> Bool {
        !isNameBlank && !isQueryBlank && !keywordValidation.blocksSave
    }
}
