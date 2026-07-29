//
//  ClickHousePluginDriver+TableOperations.swift
//  ClickHouseDriverPlugin
//

import Foundation
import TableProPluginKit

extension ClickHousePluginDriver {
    func dropObjectStatement(name: String, objectType: String, schema: String?, cascade: Bool) -> String? {
        clickHouseDropObjectStatement(name: name, objectType: objectType)
    }
}
