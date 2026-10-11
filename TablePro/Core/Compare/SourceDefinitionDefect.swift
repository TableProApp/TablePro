//
//  SourceDefinitionDefect.swift
//  TablePro
//

import Foundation

internal enum SourceDefinitionDefect: Equatable, Sendable {
    case unreadable(String)
    case empty
    case notACreateStatement

    internal static func of(_ read: RoutineSourceRead, sentAs scriptText: SQLScriptText) -> SourceDefinitionDefect? {
        if let failure = read.failure { return .unreadable(failure) }
        return of(definition: read.source, sentAs: scriptText)
    }

    internal static func of(definition: String, sentAs scriptText: SQLScriptText) -> SourceDefinitionDefect? {
        guard let first = scriptText.sendableStatements(definition).first,
              let keyword = scriptText.leadingKeyword(of: first)
        else { return .empty }
        return keyword == "CREATE" ? nil : .notACreateStatement
    }

    internal func reason(on side: ComparisonSide) -> String {
        switch (self, side) {
        case (.unreadable(let failure), .source):
            return String(format: String(localized: "The source's definition could not be read: %@"), failure)
        case (.unreadable(let failure), .target):
            return String(format: String(localized: "The target's definition could not be read: %@"), failure)
        case (.empty, .source):
            return String(localized: "The source returned an empty definition.")
        case (.empty, .target):
            return String(localized: "The target returned an empty definition.")
        case (.notACreateStatement, .source):
            return String(localized: "The source returned a body rather than a statement that recreates it.")
        case (.notACreateStatement, .target):
            return String(localized: "The target returned a body rather than a statement that recreates it.")
        }
    }
}
