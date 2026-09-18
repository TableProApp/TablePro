//
//  PluginSchemaOperation.swift
//  TableProPluginKit
//

import Foundation

public enum PluginSchemaOperation: Sendable {
    case addColumn(PluginColumnDefinition)
    case addIndex(PluginIndexDefinition)
    case renameCheckConstraint(from: String, to: String)
}
