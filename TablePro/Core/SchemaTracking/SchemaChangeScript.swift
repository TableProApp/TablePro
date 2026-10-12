//
//  SchemaChangeScript.swift
//  TablePro
//

import Foundation
import TableProPluginKit

/// A Structure save composed for one table: the statements that run, in order, the operations
/// they carry out, and the driver's review they were composed with. The driver is asked about the
/// operations and that review once more just before the first statement runs.
struct SchemaChangeScript: Sendable {
    let tableName: String
    let statements: [SchemaStatement]
    let operations: [PluginSchemaOperation]
    let review: PluginSchemaChangeReview
}
