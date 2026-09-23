//
//  PluginSchemaOperation.swift
//  TableProPluginKit
//

import Foundation

public enum PluginSchemaOperation: Sendable {
    case addColumn(PluginColumnDefinition)
    case addIndex(PluginIndexDefinition)
    case renameCheckConstraint(from: String, to: String)
    /// An index edited in place, which the app otherwise saves as a drop followed by an add.
    case modifyIndex(old: PluginIndexDefinition, new: PluginIndexDefinition)
    case dropIndex(PluginIndexDefinition)
}
