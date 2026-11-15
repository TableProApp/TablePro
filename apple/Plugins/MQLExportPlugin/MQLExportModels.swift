//
//  MQLExportModels.swift
//  MQLExportPlugin
//

import Foundation

nonisolated public struct MQLExportOptions: Equatable, Codable {
    public static let batchSizeChoices = [100, 500, 1_000, 5_000]

    public var batchSize: Int = 500

    public init() {}
}
