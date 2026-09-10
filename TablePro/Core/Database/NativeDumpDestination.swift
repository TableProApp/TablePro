//
//  NativeDumpDestination.swift
//  TablePro
//

import Foundation

/// Where each database in a backup lands, and what it is called.
///
/// A database name is not a file name. `/` and `:` are both legal in a MySQL database name and
/// neither survives a path component, so two databases can sanitize onto one name and silently
/// overwrite each other. That is worse than a clumsy name: the run reports three backups written
/// and two files exist.
enum NativeDumpDestination {
    static let timestampFormat = "yyyy-MM-dd-HHmmss"

    static func timestamp(_ date: Date) -> String {
        formatter.string(from: date)
    }

    private static let formatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = timestampFormat
        formatter.locale = Locale(identifier: "en_US_POSIX")
        return formatter
    }()

    /// The last path component for one database, without a directory in front of it.
    static func name(
        database: String,
        timestamp: String,
        fileExtension: String
    ) -> String {
        let stem = "\(sanitized(database))-\(timestamp)"
        guard !fileExtension.isEmpty else { return stem }
        return "\(stem).\(fileExtension)"
    }

    /// One destination per database, all inside `directory`, none of them colliding.
    ///
    /// Order is preserved so the sheet lists the files in the order the tree showed the databases.
    static func plan(
        databases: [String],
        in directory: URL,
        timestamp: String,
        fileExtension: String
    ) -> [(database: String, url: URL)] {
        var used: Set<String> = []
        return databases.map { database in
            var candidate = name(database: database, timestamp: timestamp, fileExtension: fileExtension)
            var attempt = 2
            while used.contains(candidate.lowercased()) {
                let stem = "\(sanitized(database))-\(timestamp)-\(attempt)"
                candidate = fileExtension.isEmpty ? stem : "\(stem).\(fileExtension)"
                attempt += 1
            }
            used.insert(candidate.lowercased())
            return (database, directory.appendingPathComponent(candidate))
        }
    }

    /// A file name the whole path stack accepts. `:` is the classic trap: HFS and APFS take it, and
    /// the Finder shows it back to the user as `/`.
    static func sanitized(_ database: String) -> String {
        let allowed = CharacterSet.alphanumerics
            .union(CharacterSet(charactersIn: "_-. "))
        let mapped = String(
            database.unicodeScalars.map { allowed.contains($0) ? Character($0) : "_" }
        ).trimmingCharacters(in: .whitespaces)
        return mapped.isEmpty ? "database" : mapped
    }

    /// Clears whatever is in the way before the engine writes.
    ///
    /// Measured on the vendored libduckdb v1.5.2: `ATTACH` onto a file that already holds a backup
    /// then `COPY FROM DATABASE` fails with `Sequence with name "s1" already exists`, and
    /// `EXPORT DATABASE` into a folder that already holds one merges, leaving the previous run's
    /// data files behind as orphans. `sqlite3` and the other tools truncate their own output, so
    /// this costs them nothing.
    static func prepare(_ url: URL, producesDirectory: Bool) throws {
        let manager = FileManager.default
        if manager.fileExists(atPath: url.path) {
            try manager.removeItem(at: url)
        }
        let parent = producesDirectory ? url : url.deletingLastPathComponent()
        try manager.createDirectory(at: parent, withIntermediateDirectories: true)
    }
}
