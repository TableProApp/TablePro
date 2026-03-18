//
//  MQLExportModels.swift
//  MQLExportPlugin
//

import Foundation

public struct MQLExportOptions: Equatable, Codable {
    public var batchSize: Int = 500

    public init() {}
}
