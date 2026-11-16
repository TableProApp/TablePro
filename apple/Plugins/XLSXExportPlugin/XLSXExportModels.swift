//
//  XLSXExportModels.swift
//  XLSXExportPlugin
//

import Foundation

nonisolated public struct XLSXExportOptions: Equatable, Codable {
    public var includeHeaderRow: Bool = true
    public var convertNullToEmpty: Bool = true

    public init() {}
}
