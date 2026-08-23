//
//  MongoDBJsonNumber.swift
//  MongoDBDriverPlugin
//

import Foundation
import TableProNumberFormatting

enum MongoDBJsonNumber {
    static func isValid(_ value: String) -> Bool {
        NumberText.isJSONNumber(value)
    }
}
