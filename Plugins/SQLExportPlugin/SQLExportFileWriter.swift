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
/// as an unsplit dump. Every part is written to a temporary file, so a failure before `commit()`
/// leaves nothing at the destination.
///
/// `commit()` publishes one part per rename and nothing renames several paths at once, so a split
/// publish is not atomic as a whole. A failure partway through names the parts that landed instead
/// of unwinding them: `replaceItemAt` keeps no backup of what stood at the path, so taking a
/// published part back would leave neither the file the user had nor the one just written. This
/// used to claim it prevented half a dump, while `rollback()` removed temps only and left every
/// already-renamed part in place unmentioned (#2533).
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
    private let encodingDeclaration: SQLExportEncodingDeclaration
    private let publish: (URL, URL) throws -> Void

    private var handle: FileHandle
    private var tempURL: URL
    private var bytesInCurrentPart = 0
    private var currentPartHasStatements = false
    private var partIndex = 1
    private var pending: [(temp: URL, final: URL)] = []
    private var published: [URL] = []
    private var didAttemptPublish = false

    /// How a finished part takes its final name. Injected so a publish that fails on one part of
    /// several can be exercised without a filesystem rigged to refuse a rename.
    internal static func publishAtomically(_ temp: URL, _ final: URL) throws {
        try PluginExportUtilities.commitAtomicWrite(from: temp, to: final)
    }

    /// The scopes still open, outermost first. Held rather than written once, because a part
    /// restored on its own has to re-establish the session state its statements were written under.
    private var openScopes: [SQLExportSessionScope] = []

    internal init(
        destination: URL,
        splitSizeMegabytes: Int,
        encodingDeclaration: SQLExportEncodingDeclaration = .empty,
        publish: @escaping (URL, URL) throws -> Void = SQLExportFileWriter.publishAtomically
    ) throws {
        self.destination = destination
        self.splitSizeBytes = max(0, splitSizeMegabytes) * 1_024 * 1_024
        self.encodingDeclaration = encodingDeclaration
        self.publish = publish
        let (handle, tempURL) = try PluginExportUtilities.beginAtomicWrite(for: destination)
        self.handle = handle
        self.tempURL = tempURL
        do {
            try beginPart()
        } catch {
            rollback()
            throw error
        }
    }

    /// True once a second part exists, so the caller can report the split rather than leaving the
    /// user to find `dump.part2.sql` themselves.
    internal var didSplit: Bool { partIndex > 1 }

    internal var partCount: Int { partIndex }

    /// Writes one statement, opening `scope` immediately in front of it.
    ///
    /// They go in together because the rotation decision sits between them: opened by a call of its
    /// own, a scope whose first statement then rotated would leave its opener alone at the end of
    /// the part above, closed there again and re-opened below it.
    internal func write(_ text: String, opening scope: SQLExportSessionScope? = nil) throws {
        let data = try text.toUTF8Data()
        let scopeBytes = (scope?.opener.utf8.count ?? 0) + (scope?.closer.utf8.count ?? 0)
        let partSize = bytesInCurrentPart + data.count + scopeBytes + partTailBytes
        if splitSizeBytes > 0, currentPartHasStatements, partSize > splitSizeBytes {
            try rotate()
        }
        if let scope {
            openScopes.append(scope)
            try writeRaw(scope.opener)
        }
        try handle.write(contentsOf: data)
        bytesInCurrentPart += data.count
        currentPartHasStatements = true
    }

    /// Closes the innermost open scope. It never rotates: the closer belongs in the part its own
    /// statements are in, and `partTailBytes` has held room for it since the scope was opened.
    internal func closeScope() throws {
        guard let scope = openScopes.popLast() else { return }
        try writeRaw(scope.closer)
    }

    /// Publishes every part and returns where they landed. An unsplit export keeps the name the
    /// user chose; a split one numbers all of its parts, so no part silently claims that name.
    /// Parts go out in order, so a publish that fails partway leaves the dump's first parts rather
    /// than a hole in the middle of it, and the failure names them.
    @discardableResult
    internal func commit() throws -> [URL] {
        try endPart()
        try handle.close()
        let finalURL = didSplit ? Self.partURL(for: destination, part: partIndex) : destination
        pending.append((tempURL, finalURL))
        didAttemptPublish = true
        for entry in pending {
            do {
                try publish(entry.temp, entry.final)
            } catch {
                discardUnpublishedTemps()
                throw SQLExportPublishFailure(
                    published: published, failed: entry.final, underlying: error)
            }
            published.append(entry.final)
        }
        return published
    }

    /// Removes the temporary files this writer still owns. Nothing to do once `commit()` has run:
    /// a commit that failed partway has already discarded the temps it did not publish, and the
    /// parts it did publish are not ours to take back.
    internal func rollback() {
        guard !didAttemptPublish else { return }
        try? handle.close()
        PluginExportUtilities.rollbackAtomicWrite(at: tempURL)
        for entry in pending {
            PluginExportUtilities.rollbackAtomicWrite(at: entry.temp)
        }
        pending.removeAll()
    }

    /// Publishing runs in order, so everything past what was published is still a temp, the part
    /// whose own publish failed included.
    private func discardUnpublishedTemps() {
        for entry in pending.dropFirst(published.count) {
            PluginExportUtilities.rollbackAtomicWrite(at: entry.temp)
        }
    }

    /// The file the caller compresses when gzip is on. Compression runs over a single file, so a
    /// split export is the one case it cannot apply to.
    internal var currentFileURL: URL { tempURL }

    private func rotate() throws {
        try endPart()
        try handle.close()
        pending.append((tempURL, Self.partURL(for: destination, part: partIndex)))
        partIndex += 1
        let (nextHandle, nextTemp) = try PluginExportUtilities.beginAtomicWrite(for: destination)
        handle = nextHandle
        tempURL = nextTemp
        bytesInCurrentPart = 0
        currentPartHasStatements = false
        try beginPart()
    }

    /// Declares the encoding and re-opens every scope that is still open, so a part carries the
    /// session state its own statements were written under.
    private func beginPart() throws {
        try writeRaw(encodingDeclaration.prologue)
        for scope in openScopes {
            try writeRaw(scope.opener)
        }
    }

    /// A part closes what it opened, innermost first, whether it ends at a rotation or at the
    /// commit. `SET IDENTITY_INSERT` used to be written as two plain statements around a table's
    /// rows, so a rotation between them ended part N on an unmatched `ON` and opened part N+1 with
    /// rows SQL Server rejects one by one (#2533).
    private func endPart() throws {
        for scope in openScopes.reversed() {
            try writeRaw(scope.closer)
        }
        try writeRaw(encodingDeclaration.epilogue)
    }

    /// What the part still owes: the closer of every open scope and the closing declaration. Every
    /// write counts it, because a part that fits only until its own tail is added has not fitted.
    private var partTailBytes: Int {
        openScopes.reduce(encodingDeclaration.epilogue.utf8.count) { $0 + $1.closer.utf8.count }
    }

    private func writeRaw(_ text: String) throws {
        guard !text.isEmpty else { return }
        let data = try text.toUTF8Data()
        try handle.write(contentsOf: data)
        bytesInCurrentPart += data.count
    }
}

/// A split dump is published one rename at a time, so a failure partway through has already put
/// the earlier parts on disk. Naming them is the whole point of this error: the alert that reports
/// the failure is the only place the user hears which files the export did write, and they cannot
/// be taken back, because `replaceItemAt` keeps no backup of what stood at the path.
internal struct SQLExportPublishFailure: LocalizedError {
    internal let published: [URL]
    internal let failed: URL
    internal let underlying: any Error

    internal var errorDescription: String? {
        let name = failed.lastPathComponent
        let reason = underlying.localizedDescription
        guard !published.isEmpty else {
            return String(format: String(localized: "Could not write %1$@. %2$@"), name, reason)
        }
        return String(
            format: String(localized:
                "Could not write %1$@. %2$@ These parts were written and are still on disk: %3$@"),
            name,
            reason,
            published.map(\.lastPathComponent).joined(separator: ", "))
    }
}
