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
    let functionNamesAreCaseInsensitive: Bool

    init(descriptor: SQLDialectDescriptor) {
        self.identifierQuote = descriptor.identifierQuote
        self.keywords = descriptor.keywords
        self.functions = descriptor.functions
        self.dataTypes = descriptor.dataTypes
        self.functionNamesAreCaseInsensitive = descriptor.functionNamesAreCaseInsensitive
    }
}

// MARK: - Empty Dialect

private struct EmptyDialect: SQLDialectProvider {
    let identifierQuote = "\""
    let keywords: Set<String> = []
    let functions: Set<String> = []
    let dataTypes: Set<String> = []
    let functionNamesAreCaseInsensitive = false
}

// MARK: - Dialect Factory

struct SQLDialectFactory {
    static func createDialect(for databaseType: DatabaseType) -> SQLDialectProvider {
        if let descriptor = PluginMetadataRegistry.shared.snapshot(
            for: databaseType
        )?.editor.sqlDialect {
            return PluginDialectAdapter(descriptor: descriptor)
        }
        return EmptyDialect()
    }
}
