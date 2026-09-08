//
//  DuckDBLockConflict.swift
//  DuckDBDriverPlugin
//
//  Parsing for DuckDB's lock-conflict text. No CDuckDB import, so TableProTests can
//  exercise it without loading the plugin bundle.
//

import Foundation

/// DuckDB reports a lock conflict only as text: `duckdb_open_ext` hands back a `char **`
/// and nothing else, with no `duckdb_error_data` and no `duckdb_error_type` for an open, so
/// the string is the whole channel. Measured against the shipped v1.5.2, that string already
/// names the process holding the file:
///
///     IO Error: Could not set lock on file "<path>": Conflicting lock is held in
///     <holder executable path> (PID 65252) by user <user>. See also https://duckdb.org/...
///
/// A holder that itself opened read-only appends "However, you would be able to open this
/// database in read-only mode" before that URL, which is DuckDB's own signal that a read-only
/// retry would succeed. Everything past the anchor is optional so a reworded DuckDB release
/// degrades to "another process has the file" instead of failing to classify at all.
struct DuckDBLockConflict: Equatable {
    let filePath: String?
    let holderExecutablePath: String?
    let holderProcessId: Int?
    let holderUser: String?

    /// Whether DuckDB said a read-only open would get in, which it does only when the current
    /// holder is itself read-only. Absent when the holder has the file read-write, because then
    /// no access mode gets in.
    let readOnlyWouldSucceed: Bool

    /// The last path component, which is the name a person recognises. DuckDB names the whole
    /// executable, so another TablePro window reads as
    /// `/Applications/TablePro.app/Contents/MacOS/TablePro`.
    var holderName: String? {
        guard let holderExecutablePath, !holderExecutablePath.isEmpty else { return nil }
        let name = (holderExecutablePath as NSString).lastPathComponent
        return name.isEmpty ? nil : name
    }

    private static let anchor = "Could not set lock on file"
    private static let holderPrefix = "Conflicting lock is held in "
    private static let processIdPrefix = " (PID "
    private static let userPrefix = " by user "
    private static let readOnlyHint = "open this database in read-only mode"

    static func parse(_ message: String) -> DuckDBLockConflict? {
        guard message.contains(anchor) else { return nil }
        return DuckDBLockConflict(
            filePath: firstQuotedValue(in: message),
            holderExecutablePath: value(in: message, after: holderPrefix, upTo: processIdPrefix),
            holderProcessId: value(in: message, after: processIdPrefix, upTo: ")").flatMap(Int.init),
            holderUser: user(in: message),
            readOnlyWouldSucceed: message.contains(readOnlyHint)
        )
    }

    private static func firstQuotedValue(in message: String) -> String? {
        guard let anchorRange = message.range(of: anchor),
              let openingQuote = message.range(of: "\"", range: anchorRange.upperBound..<message.endIndex),
              let closingQuote = message.range(of: "\"", range: openingQuote.upperBound..<message.endIndex)
        else { return nil }
        return nonEmpty(String(message[openingQuote.upperBound..<closingQuote.lowerBound]))
    }

    /// The username runs to the end of DuckDB's sentence, and both known continuations
    /// ("See also" and "However") follow a full stop and a space. Cutting there keeps a name
    /// that contains a dot of its own intact.
    private static func user(in message: String) -> String? {
        guard let prefixRange = message.range(of: userPrefix) else { return nil }
        let remainder = message[prefixRange.upperBound...]
        guard let sentenceEnd = remainder.range(of: ". ") else {
            return nonEmpty(String(remainder).trimmingCharacters(in: CharacterSet(charactersIn: ". ")))
        }
        return nonEmpty(String(remainder[..<sentenceEnd.lowerBound]))
    }

    private static func value(in message: String, after prefix: String, upTo terminator: String) -> String? {
        guard let prefixRange = message.range(of: prefix),
              let terminatorRange = message.range(
                  of: terminator,
                  range: prefixRange.upperBound..<message.endIndex
              )
        else { return nil }
        return nonEmpty(String(message[prefixRange.upperBound..<terminatorRange.lowerBound]))
    }

    private static func nonEmpty(_ value: String) -> String? {
        value.isEmpty ? nil : value
    }
}

extension DuckDBLockConflict {
    /// What the user is told. DuckDB's own sentence names the holder, a path and a
    /// documentation URL, which is more than a person needs and less than they can act on, so
    /// the holder's name is promoted to the front and the rest is dropped.
    var localizedDescription: String {
        let file = filePath.map { ($0 as NSString).lastPathComponent } ?? String(localized: "the database file")
        guard let holderName else {
            return String(
                format: String(localized: "Another app is using %@. Only one app can open a DuckDB file for writing."),
                file
            )
        }
        return String(
            format: String(localized: "%@ is using %@. Only one app can open a DuckDB file for writing."),
            holderName,
            file
        )
    }

    /// Read-only is worth offering only when DuckDB said it would work. Suggesting it against a
    /// read-write holder sends the user to a setting that fails with the same lock error.
    var recoverySuggestion: String? {
        guard readOnlyWouldSucceed else {
            return String(localized: "Quit or disconnect the other app, then try again.")
        }
        return String(localized: "Quit or disconnect the other app, or turn on Open the File Read-Only to join it as a reader.")
    }
}
