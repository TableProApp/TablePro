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
    /// A column changed in place. For a document store, a rename carried out on every document
    /// that holds the field.
    case modifyColumn(old: PluginColumnDefinition, new: PluginColumnDefinition)
    case dropColumn(PluginColumnDefinition)
}
