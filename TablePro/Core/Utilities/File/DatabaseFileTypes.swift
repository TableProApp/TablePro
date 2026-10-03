//
//  DatabaseFileTypes.swift
//  TablePro
//

import Foundation
import UniformTypeIdentifiers

/// Turns a driver's file extensions into the content types a save panel names a new database with.
///
/// Only a save panel: an open panel filtered this way matches names alone, so it disables a
/// database saved with no extension or under another app's, which `DatabaseFileBrowseRule` reaches
/// by reading the file instead.
enum DatabaseFileTypes {
    /// Most database extensions are not registered system types, so
    /// `UTType(filenameExtension:)` alone returns nil for them. Declaring conformance to
    /// `.data` makes the system mint a dynamic type, which the panel filters on by extension.
    ///
    /// Two extensions can resolve to one type, and whether they do depends on what is
    /// installed: a Mac with the DuckDB CLI resolves both `duckdb` and `ddb` to
    /// `org.duckdb.duckdb-database`, and a Mac without it mints a separate dynamic type for
    /// each. Duplicates are dropped so the panel's format list does not repeat itself, and
    /// the first occurrence keeps its place so the driver's own ordering survives.
    static func contentTypes(forExtensions extensions: [String]) -> [UTType] {
        var seen: Set<UTType> = []
        let types = extensions.compactMap { rawExtension -> UTType? in
            let trimmed = rawExtension.trimmingCharacters(in: CharacterSet(charactersIn: ". "))
            guard !trimmed.isEmpty,
                  let type = UTType(filenameExtension: trimmed, conformingTo: .data),
                  seen.insert(type).inserted
            else { return nil }
            return type
        }
        return types.isEmpty ? [.data] : types
    }
}
