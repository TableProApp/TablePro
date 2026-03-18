//
//  ClickHousePartInfo.swift
//  TablePro
//
//  Model for ClickHouse partition/part information from system.parts.
//

import Foundation

/// Represents a single part from the ClickHouse system.parts table
struct ClickHousePartInfo: Identifiable {
    let id = UUID()
    let partition: String
    let name: String
    let rows: UInt64
    let bytesOnDisk: UInt64
    let modificationTime: String
    let active: Bool
}
