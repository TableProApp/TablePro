//
//  PluginDriverAdapter+CreateTableForm.swift
//  TablePro
//

import Foundation
import TableProPluginKit

internal extension PluginDriverAdapter {
    func createTableFormSpec(schema: String?) -> PluginCreateTableFormSpec? {
        pluginDriver.createTableFormSpec(schema: schema)
    }

    func createTableStatements(for request: PluginCreateTableRequest, schema: String?) throws -> [String] {
        try pluginDriver.createTableStatements(for: request, schema: schema)
    }
}
