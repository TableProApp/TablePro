//
//  PluginExportOutputBuffer.swift
//  TablePro
//

import Foundation

nonisolated struct PluginExportOutputBuffer {
    static let defaultFlushThreshold = 1 << 20

    private let fileHandle: FileHandle
    private let flushThreshold: Int
    private var pending: [UInt8] = []

    init(fileHandle: FileHandle, flushThreshold: Int = Self.defaultFlushThreshold) {
        self.fileHandle = fileHandle
        self.flushThreshold = flushThreshold
        pending.reserveCapacity(flushThreshold)
    }

    mutating func append(_ text: String) throws {
        var text = text
        try text.withUTF8 { try append(UnsafeRawBufferPointer($0)) }
    }

    mutating func append(_ data: Data) throws {
        try data.withUnsafeBytes { try append($0) }
    }

    mutating func append(_ bytes: [UInt8]) throws {
        try bytes.withUnsafeBytes { try append($0) }
    }

    mutating func flush() throws {
        guard !pending.isEmpty else { return }
        try pending.withUnsafeBytes { try fileHandle.write(contentsOf: $0) }
        pending.removeAll(keepingCapacity: true)
    }

    // A value past the threshold goes straight to the file, so the buffer never grows to hold it.
    private mutating func append(_ bytes: UnsafeRawBufferPointer) throws {
        guard bytes.count < flushThreshold else {
            try flush()
            try fileHandle.write(contentsOf: bytes)
            return
        }
        pending.append(contentsOf: bytes)
        if pending.count >= flushThreshold {
            try flush()
        }
    }
}
