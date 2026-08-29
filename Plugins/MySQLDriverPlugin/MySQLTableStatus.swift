//
//  MySQLTableStatus.swift
//  MySQLDriverPlugin
//
//  Reads one `SHOW TABLE STATUS` row by its documented column order.
//

import Foundation
import TableProPluginKit

/// `SHOW TABLE STATUS` answers positionally, and the app used to read four of its eighteen columns
/// by hand-written index. Naming every column the Properties tab shows keeps those indexes in one
/// place instead of scattering more of them through the driver.
struct MySQLTableStatus {
    let engine: String?
    let rowFormat: String?
    let rowCount: Int64?
    let avgRowLength: Int64?
    let dataSize: Int64?
    let indexSize: Int64?
    let autoIncrement: Int64?
    let createTime: Date?
    let updateTime: Date?
    let collation: String?
    let createOptions: String?
    let comment: String?

    init(row: [PluginCellValue]) {
        engine = Self.text(row, 1)
        rowFormat = Self.text(row, 3)
        rowCount = Self.number(row, 4)
        avgRowLength = Self.number(row, 5)
        dataSize = Self.number(row, 6)
        indexSize = Self.number(row, 8)
        autoIncrement = Self.number(row, 10)
        createTime = Self.timestamp(row, 11)
        updateTime = Self.timestamp(row, 12)
        collation = Self.text(row, 14)
        createOptions = Self.text(row, 16)
        comment = Self.text(row, 17)
    }

    /// `SHOW TABLE STATUS` answers for a view with every storage column NULL, `Engine` included,
    /// and reports the literal `VIEW` where a table's comment would be. MySQL has no `COMMENT` form
    /// for a view, so a row that names no engine is treated as one and its comment stays read-only.
    var commentIsReadOnly: Bool {
        engine == nil
    }

    var attributes: [PluginObjectAttribute] {
        var result: [PluginObjectAttribute] = []
        if let rowFormat {
            result.append(PluginObjectAttribute(label: String(localized: "Row Format"), value: rowFormat))
        }
        if let autoIncrement {
            result.append(
                PluginObjectAttribute(label: String(localized: "Auto Increment"), value: String(autoIncrement))
            )
        }
        if let createOptions {
            result.append(PluginObjectAttribute(label: String(localized: "Options"), value: createOptions))
        }
        return result
    }

    private static func text(_ row: [PluginCellValue], _ index: Int) -> String? {
        guard let value = row[safe: index]?.asText, !value.isEmpty else { return nil }
        return value
    }

    private static func number(_ row: [PluginCellValue], _ index: Int) -> Int64? {
        text(row, index).flatMap { Int64($0) }
    }

    /// MySQL sends these as `YYYY-MM-DD HH:MM:SS` in the session time zone and carries no offset,
    /// so the instant they name cannot be recovered from the string alone. Reading them in the
    /// client's zone is deliberate: the app formats the `Date` back in that same zone, so what the
    /// user reads is the wall clock the server reported. Fixing the formatter to UTC would be a
    /// guess at the server's zone and would shift every displayed timestamp by that guess.
    private static let timestampFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return formatter
    }()

    private static func timestamp(_ row: [PluginCellValue], _ index: Int) -> Date? {
        guard let value = text(row, index) else { return nil }
        return timestampFormatter.date(from: value)
    }
}
