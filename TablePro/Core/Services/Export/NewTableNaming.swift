//
//  NewTableNaming.swift
//  TablePro
//

import Foundation

enum NewTableNameProblem: Equatable {
    case blank
    case nameTaken
    case reservedPrefix(String)
    case tooLong(maximumBytes: Int)
}

/// How an engine treats a table name written without quotes, and what it refuses outright.
///
/// The import sheet always quotes the name it creates, so the casing only decides whether the table
/// can be named without quotes in a query written later. The other two are harder rules: a name past
/// the engine's limit is rejected, and PostgreSQL truncates it silently instead, which lands two
/// imports in one table.
struct NewTableNameStyle: Equatable {
    enum Casing: Equatable {
        case lower
        case upper
    }

    let casing: Casing
    let maximumByteLength: Int

    /// A prefix the engine keeps for itself. Measured against the vendored SQLite: `CREATE TABLE
    /// "sqlite_backup"` fails with "object name reserved for internal use" even quoted and whatever
    /// its case, and `SQLitePlugin.fetchTables` hides those objects, so a collision check cannot
    /// rescue the name either. A proposal carrying it could never be imported.
    let reservedPrefix: String?

    /// Oracle folds an unquoted identifier to upper case and caps it at 30 bytes until the server
    /// runs 12.2 or later with `COMPATIBLE` raised. TablePro connects back to 11.1 and the login
    /// never reports `COMPATIBLE`, so the shorter limit is the only one a suggestion can assume.
    /// Snowflake folds to upper case too. Everything else folds to lower, and 63 bytes is
    /// PostgreSQL's limit and under MySQL's.
    static func forDatabaseType(_ databaseType: DatabaseType) -> NewTableNameStyle {
        switch databaseType {
        case .oracle:
            return NewTableNameStyle(casing: .upper, maximumByteLength: 30, reservedPrefix: nil)
        case .snowflake:
            return NewTableNameStyle(casing: .upper, maximumByteLength: 63, reservedPrefix: nil)
        case .sqlite, .libsql, .turso, .cloudflareD1:
            return NewTableNameStyle(casing: .lower, maximumByteLength: 63, reservedPrefix: "sqlite_")
        default:
            return NewTableNameStyle(casing: .lower, maximumByteLength: 63, reservedPrefix: nil)
        }
    }
}

/// The name an import proposes for the table it is about to create, and what is wrong with the
/// name the user left in the field.
///
/// A file name is not an identifier: APFS accepts every scalar but `/` and NUL, so a stem arrives
/// holding spaces, punctuation, emoji and combining marks. Mapping the ones outside
/// `CharacterSet.alphanumerics` onto `_` keeps letters and digits from every script, which matters
/// because that set spans Unicode `L*` and `M*`: a Cyrillic or CJK file name survives as itself
/// rather than being transliterated into something the user never wrote.
enum NewTableNaming {
    private static let fallbackStem = "imported_data"
    private static let safetyPrefix = "t_"
    private static let separator: Character = "_"

    /// Names compare case-insensitively because the engines disagree about whether they should:
    /// PostgreSQL folds an unquoted name, macOS MySQL compares one case-insensitively, and a
    /// suggestion that differs from an existing table only in case is a collision on both.
    static func comparisonKeys(for names: some Sequence<String>) -> Set<String> {
        Set(names.map { $0.lowercased() })
    }

    static func suggestion(
        forFileNamed fileName: String,
        style: NewTableNameStyle,
        avoiding existingKeys: Set<String>
    ) -> String {
        let stem = URL(fileURLWithPath: fileName).deletingPathExtension().lastPathComponent
        let shaped = shaping(identifier(from: stem), style: style)
        var fitted = truncating(shaped, toByteLength: style.maximumByteLength)
        if fitted.isEmpty {
            fitted = truncating(
                shaping(fallbackStem, style: style), toByteLength: style.maximumByteLength
            )
        }
        return disambiguating(fitted, style: style, avoiding: existingKeys)
    }

    /// The engine's rules apply to whatever is in the field, not just to what was proposed: the
    /// suggestion is only a starting point and the user is free to type a name the server will
    /// refuse. Catching that here is the whole point of the check, since the alternative is the
    /// driver's own error after the sheet has dismissed.
    ///
    /// `existingNames` is `nil` when the table list never loaded. A collision cannot be ruled out
    /// then, and it must not be ruled in either: reporting one name as taken because the catalog
    /// is unreachable would block an import the engine would have accepted.
    static func problem(
        with name: String,
        style: NewTableNameStyle,
        existingNames: Set<String>?
    ) -> NewTableNameProblem? {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return .blank }
        if let reserved = style.reservedPrefix, trimmed.lowercased().hasPrefix(reserved.lowercased()) {
            return .reservedPrefix(reserved)
        }
        if trimmed.utf8.count > style.maximumByteLength {
            return .tooLong(maximumBytes: style.maximumByteLength)
        }
        guard let existingNames else { return nil }
        return existingNames.contains(trimmed.lowercased()) ? .nameTaken : nil
    }

    /// Runs of rejected scalars collapse onto one separator, and a run at either end produces
    /// none, so `.hidden` yields `hidden` and `sales - 2024` yields `sales_2024`.
    private static func identifier(from stem: String) -> String {
        let allowed = CharacterSet.alphanumerics
        var result = ""
        var separatorPending = false
        for scalar in stem.precomposedStringWithCanonicalMapping.unicodeScalars {
            guard allowed.contains(scalar) else {
                separatorPending = true
                continue
            }
            if separatorPending, !result.isEmpty {
                result.append(separator)
            }
            separatorPending = false
            result.unicodeScalars.append(scalar)
        }
        return result
    }

    /// A stem that survives as nothing, one that survives as digits, and one carrying the engine's
    /// own reserved prefix all need characters the file did not supply: no mainstream unquoted
    /// identifier grammar admits a leading digit, and a reserved prefix is refused outright.
    private static func shaping(_ identifier: String, style: NewTableNameStyle) -> String {
        var name = identifier
        if name.isEmpty {
            name = fallbackStem
        }
        if let first = name.unicodeScalars.first, CharacterSet.decimalDigits.contains(first) {
            name = safetyPrefix + name
        }
        if let reserved = style.reservedPrefix,
           name.lowercased().hasPrefix(reserved.lowercased()) {
            name = safetyPrefix + name
        }
        switch style.casing {
        case .lower: return name.lowercased()
        case .upper: return name.uppercased()
        }
    }

    /// Cuts on a `Character` boundary while counting UTF-8 bytes, because the engines state their
    /// limits in bytes and a multi-byte name would otherwise be cut mid-grapheme.
    private static func truncating(_ name: String, toByteLength limit: Int) -> String {
        guard name.utf8.count > limit else { return name }
        var result = ""
        var usedBytes = 0
        for character in name {
            let width = String(character).utf8.count
            guard usedBytes + width <= limit else { break }
            result.append(character)
            usedBytes += width
        }
        return trimmingSeparators(result)
    }

    private static func trimmingSeparators(_ name: String) -> String {
        var trimmed = Substring(name)
        while trimmed.first == separator { trimmed = trimmed.dropFirst() }
        while trimmed.last == separator { trimmed = trimmed.dropLast() }
        return String(trimmed)
    }

    /// One more candidate than there are names guarantees a free one, so the walk is bounded by
    /// the catalog rather than by a constant that a large schema could exhaust.
    private static func disambiguating(
        _ name: String,
        style: NewTableNameStyle,
        avoiding existingKeys: Set<String>
    ) -> String {
        guard existingKeys.contains(name.lowercased()) else { return name }
        var candidate = name
        for index in 2...(existingKeys.count + 2) {
            let suffix = "\(separator)\(index)"
            let room = max(1, style.maximumByteLength - suffix.utf8.count)
            candidate = truncating(name, toByteLength: room) + suffix
            if !existingKeys.contains(candidate.lowercased()) { return candidate }
        }
        return candidate
    }
}
