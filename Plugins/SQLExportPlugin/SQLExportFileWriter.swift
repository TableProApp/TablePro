//
//  SQLExportFileWriter.swift
//  SQLExportPlugin
//

import Foundation
import TableProPluginKit

/// Writes a dump, starting a new file once the current one passes a size cap.
///
/// Rotation happens between writes and never inside one, so a part always ends on a complete
/// statement: a restore that replays the parts in order gets the same statements in the same order
/// as an unsplit dump. Every part is written to a temporary file and committed at the end, which is
/// what keeps a failed or cancelled export from leaving half a dump behind.
internal final class SQLExportFileWriter {
    /// The name a part takes: `dump.sql` becomes `dump.part1.sql`, and a compound extension like
    /// `dump.sql.gz` becomes `dump.part1.sql.gz`.
    internal static func partURL(for destination: URL, part: Int) -> URL {
        let name = destination.lastPathComponent
        guard let firstDot = name.firstIndex(of: ".") else {
            return destination.deletingLastPathComponent().appendingPathComponent("\(name).part\(part)")
        }
        let base = String(name[name.startIndex ..< firstDot])
        let suffix = String(name[firstDot...])
        return destination.deletingLastPathComponent().appendingPathComponent("\(base).part\(part)\(suffix)")
    }

    private let destination: URL
    private let splitSizeBytes: Int

    private var handle: FileHandle
    private var tempURL: URL
    private var bytesInCurrentPart = 0
    private var partIndex = 1
    private var pending: [(temp: URL, final: URL)] = []
    private var isCommitted = false

    internal init(destination: URL, splitSizeMegabytes: Int) throws {
        self.destination = destination
        self.splitSizeBytes = max(0, splitSizeMegabytes) * 1_024 * 1_024
        let (handle, tempURL) = try PluginExportUtilities.beginAtomicWrite(for: destination)
        self.handle = handle
        self.tempURL = tempURL
    }

    /// True once a second part exists, so the caller can report the split rather than leaving the
    /// user to find `dump.part2.sql` themselves.
    internal var didSplit: Bool { partIndex > 1 }

    internal var partCount: Int { partIndex }

    internal func write(_ text: String) throws {
        let data = try text.toUTF8Data()
        if splitSizeBytes > 0, bytesInCurrentPart > 0, bytesInCurrentPart + data.count > splitSizeBytes {
            try rotate()
        }
        try handle.write(contentsOf: data)
        bytesInCurrentPart += data.count
    }

    /// Publishes every part and returns where they landed. An unsplit export keeps the name the
    /// user chose; a split one numbers all of its parts, so no part silently claims that name.
    @discardableResult
    internal func commit() throws -> [URL] {
        try handle.close()
        let finalURL = didSplit ? Self.partURL(for: destination, part: partIndex) : destination
        pending.append((tempURL, finalURL))
        for entry in pending {
            try PluginExportUtilities.commitAtomicWrite(from: entry.temp, to: entry.final)
        }
        isCommitted = true
        return pending.map(\.final)
    }

    /// Removes every temporary file. Safe to call after a commit, where it finds nothing to remove.
    internal func rollback() {
        guard !isCommitted else { return }
        try? handle.close()
        PluginExportUtilities.rollbackAtomicWrite(at: tempURL)
        for entry in pending {
            PluginExportUtilities.rollbackAtomicWrite(at: entry.temp)
        }
        pending.removeAll()
    }

    /// The file the caller compresses when gzip is on. Compression runs over a single file, so a
    /// split export is the one case it cannot apply to.
    internal var currentFileURL: URL { tempURL }

    private func rotate() throws {
        try handle.close()
        pending.append((tempURL, Self.partURL(for: destination, part: partIndex)))
        partIndex += 1
        let (nextHandle, nextTemp) = try PluginExportUtilities.beginAtomicWrite(for: destination)
        handle = nextHandle
        tempURL = nextTemp
        bytesInCurrentPart = 0
    }
}
