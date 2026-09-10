//
//  LocalFilePathField.swift
//  TablePro
//

import Foundation

/// Where a file-backed driver keeps the path of the database file it opens.
///
/// Curated per database type rather than read from `DriverPlugin`, for the reason
/// `PluginMetadataRegistry.buildMetadataSnapshot` records: a static read off a plugin built before
/// that static existed crashes with `EXC_BAD_INSTRUCTION` on a missing witness table entry. Keeping
/// it app-side also means an already-installed DuckDB or libSQL plugin can open a remote file with
/// no re-release at all.
///
/// `pathFieldRole` cannot answer this question. It reports `.filePath` for SQLite and Beancount
/// only; DuckDB and libSQL open local files while declaring `.database`, and keep the path in a
/// plugin-declared additional field rather than in `database`.
enum LocalFilePathField: Sendable, Equatable, Hashable {
    /// The built-in `database` field, as SQLite and Beancount use it.
    case database

    /// A plugin-declared additional field, carrying its field id. DuckDB uses `duckdbFilePath` and
    /// libSQL uses `libsqlFilePath`.
    case additionalField(String)
}
