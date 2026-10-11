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

    func objectCommentStatement(name: String, objectType: String, schema: String?, comment: String?) -> String? {
        clickHouseCommentStatement(
            name: name,
            database: schema,
            objectType: objectType,
            comment: comment,
            capabilities: ClickHouseCapabilities.parse(serverVersion)
        )
    }
}
