//
//  ClickHousePartInfo.swift
//  TablePro
//

import Foundation

struct ClickHousePartInfo: Identifiable {
    let id = UUID()
    let partition: String
    let partitionId: String
    let name: String
    let rows: UInt64
    let bytesOnDisk: UInt64
    let modificationTime: String
    let active: Bool
}
