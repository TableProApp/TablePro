//
//  JSONFieldDetectionCache.swift
//  JSONImportPlugin
//

import Foundation
import os
import TableProPluginKit

/// The fields of the last JSON Lines file read, kept against that file's identity.
///
/// A JSON Lines file's fields do not depend on the table they are matched against, and reading
/// them means reading every line. The import sheet asks again on every destination table pick, so
/// each pick used to read the whole file again.
final class JSONFieldDetectionCache: Sendable {
    /// A file counts as unchanged while its path, file number, size and modification date all
    /// match. The identity is taken before the read, so an edit made during one leaves a stale
    /// identity behind and the next request reads the file again. It describes the file a link
    /// points to, because `attributesOfItem` describes the link itself and the read follows it.
    private struct FileIdentity: Equatable, Sendable {
        let path: String
        let fileNumber: UInt64?
        let size: UInt64?
        let modificationDate: Date?

        init(of url: URL) throws {
            let file = url.resolvingSymlinksInPath()
            let attributes = try FileManager.default.attributesOfItem(atPath: file.path)
            path = file.path
            fileNumber = (attributes[.systemFileNumber] as? NSNumber)?.uint64Value
            size = (attributes[.size] as? NSNumber)?.uint64Value
            modificationDate = attributes[.modificationDate] as? Date
        }
    }

    private struct Entry: Sendable {
        let file: FileIdentity
        let fields: [PluginImportField]
    }

    private let lastEntry = OSAllocatedUnfairLock<Entry?>(initialState: nil)

    func fields(at url: URL, detect: () throws -> [PluginImportField]) throws -> [PluginImportField] {
        let file = try FileIdentity(of: url)
        if let cached = lastEntry.withLock({ $0?.file == file ? $0?.fields : nil }) {
            return cached
        }
        let fields = try detect()
        lastEntry.withLock { $0 = Entry(file: file, fields: fields) }
        return fields
    }
}
