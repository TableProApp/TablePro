//
//  PluginDriverAdapter+CreateTableForm.swift
//  TablePro
//

import Foundation
import TableProPluginKit

internal extension PluginDriverAdapter {
    func createTableFormSpec(schema: String?) -> PluginCreateTableFormSpec? {
        schemaPluginDriver.createTableFormSpec(schema: schema)
    }

    func createTableStatements(for request: PluginCreateTableRequest, schema: String?) throws -> [String] {
        try schemaPluginDriver.createTableStatements(for: request, schema: schema)
    }
}
