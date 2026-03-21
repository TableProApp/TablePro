//
//  SQLDialectProvider.swift
//  TablePro
//
//  Created by OpenCode on 1/17/26.
//

import Foundation
import TableProPluginKit

// MARK: - Plugin Dialect Adapter

struct PluginDialectAdapter: SQLDialectProvider {
    let identifierQuote: String
    let keywords: Set<String>
    let functions: Set<String>
    let dataTypes: Set<String>

    init(descriptor: SQLDialectDescriptor) {
        self.identifierQuote = descriptor.identifierQuote
        self.keywords = descriptor.keywords
        self.functions = descriptor.functions
        self.dataTypes = descriptor.dataTypes
    }
}

// MARK: - Empty Dialect

/// Fallback dialect with no keywords/functions. Internal visibility so SQLFormatterService
/// can use it as a fallback when resolving dialects off the main thread.
internal struct EmptyDialect: SQLDialectProvider {
    let identifierQuote = "\""
    let keywords: Set<String> = []
    let functions: Set<String> = []
    let dataTypes: Set<String> = []
}

// MARK: - Dialect Factory

struct SQLDialectFactory {
    @MainActor
    static func createDialect(for databaseType: DatabaseType) -> SQLDialectProvider {
        if let descriptor = PluginManager.shared.sqlDialect(for: databaseType) {
            return PluginDialectAdapter(descriptor: descriptor)
        }
        return EmptyDialect()
    }
}
