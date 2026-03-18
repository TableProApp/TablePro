//
//  SQLExportModels.swift
//  SQLExportPlugin
//

import Foundation

public struct SQLExportOptions: Equatable, Codable {
    public var compressWithGzip: Bool = false
    public var batchSize: Int = 500

    public init() {}
}
