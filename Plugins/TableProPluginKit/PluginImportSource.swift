//
//  PluginImportSource.swift
//  TableProPluginKit
//

import Foundation

public protocol PluginImportSource: AnyObject, Sendable {
    func statements() async throws -> AsyncThrowingStream<(statement: String, lineNumber: Int), Error>
    func fileURL() -> URL
    func fileSizeBytes() -> Int64
    func cleanup()
}

public extension PluginImportSource {
    func cleanup() {}
}
