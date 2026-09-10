//
//  PluginCellValueBox.swift
//  SnowflakeDriverPlugin
//
//  JSON-decoded cell value before conversion to PluginCellValue (kept Sendable for streaming).
//

import Foundation

enum PluginCellValueBox: Sendable {
    case null
    case text(String)
    case bytes(Data)
}
