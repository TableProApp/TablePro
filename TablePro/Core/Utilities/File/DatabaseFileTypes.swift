//
//  DatabaseFileTypes.swift
//  TablePro
//

import Foundation
import UniformTypeIdentifiers

/// Turns a driver's declared file extensions into the content types its Browse panel offers.
///
/// The panel used to allow `[.database, .data]`, which is every file on disk, so a DuckDB
/// connection let you pick a `.png` and a SQLite connection let you pick a `.parquet`. The
/// driver is the only thing that knows what it can open, and it already declares that list.
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
