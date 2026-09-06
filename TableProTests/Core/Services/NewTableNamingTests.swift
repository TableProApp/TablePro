//
//  NewTableNamingTests.swift
//  TableProTests
//

@testable import TablePro
import Testing

/// A row import that creates its table used to open with an empty name field, so the name reached
/// `CREATE TABLE` unchecked and the server was the first thing to judge it.
@Suite("New table naming")
struct NewTableNamingTests {
    private let postgres = NewTableNameStyle.forDatabaseType(.postgresql)

    private func suggestion(_ fileName: String, taken: [String] = []) -> String {
        NewTableNaming.suggestion(
            forFileNamed: fileName,
            style: postgres,
            avoiding: NewTableNaming.comparisonKeys(for: taken)
        )
    }

    // MARK: - Shaping the file name

    @Test("Punctuation and spaces collapse onto single separators")
    func punctuationCollapses() {
        #expect(suggestion("sales-2024 Q1.csv") == "sales_2024_q1")
        #expect(suggestion("a  -  b.csv") == "a_b")
    }

    /// `CharacterSet.alphanumerics` spans Unicode `L*` and `M*`, so a name written in any script
    /// survives as itself. Transliterating would hand the user a name their file never held.
    @Test("Letters from every script survive")
    func nonLatinSurvives() {
        #expect(suggestion("销售数据.csv") == "销售数据")
        #expect(suggestion("продажи.csv") == "продажи")
        #expect(suggestion("naïve-café 2024.csv") == "naïve_café_2024")
    }

    /// APFS hands back decomposed text, so an accented name arrives as a letter plus a combining
    /// mark. Without the NFC pass the two spellings are different table names.
    @Test("Decomposed input normalizes to the composed spelling")
    func decomposedInputNormalizes() {
        #expect(suggestion("cafe\u{0301}.csv") == suggestion("caf\u{00E9}.csv"))
    }

    @Test("Emoji and symbols become separators")
    func symbolsBecomeSeparators() {
        #expect(suggestion("emoji🚀name.csv") == "emoji_name")
    }

    /// Only the last extension goes, so a dotfile keeps its stem instead of yielding nothing.
    /// A leading dot is not an extension separator to Foundation, so a file named `.csv` has no
    /// extension at all and its whole name is the stem, which shapes into a usable `csv`.
    @Test("Only the final extension is dropped")
    func onlyFinalExtensionDropped() {
        #expect(suggestion(".hidden.csv") == "hidden")
        #expect(suggestion("a.b.c.tsv") == "a_b_c")
        #expect(suggestion("no_extension") == "no_extension")
        #expect(suggestion(".csv") == "csv")
    }

    @Test("A stem that survives as nothing falls back to a usable name")
    func emptyStemFallsBack() {
        #expect(suggestion("---.csv") == "imported_data")
        #expect(suggestion("🚀.csv") == "imported_data")
    }

    /// No mainstream unquoted identifier grammar admits a leading digit, and MySQL rejects an
    /// all-digit one outright.
    @Test("A leading digit gains a letter prefix")
    func leadingDigitPrefixed() {
        #expect(suggestion("2024.csv") == "t_2024")
        #expect(suggestion("1st-quarter.csv") == "t_1st_quarter")
        #expect(suggestion("q1-2024.csv") == "q1_2024")
    }

    // MARK: - Engine style

    @Test("Oracle folds to upper case and caps the name at 30 bytes")
    func oracleStyle() {
        let style = NewTableNameStyle.forDatabaseType(.oracle)
        #expect(style.casing == .upper)
        #expect(style.maximumByteLength == 30)
        let name = NewTableNaming.suggestion(forFileNamed: "sales-2024 Q1.csv", style: style, avoiding: [])
        #expect(name == "SALES_2024_Q1")
    }

    @Test("Snowflake folds to upper case too")
    func snowflakeStyle() {
        let style = NewTableNameStyle.forDatabaseType(.snowflake)
        #expect(style.casing == .upper)
        let name = NewTableNaming.suggestion(forFileNamed: "Sales.csv", style: style, avoiding: [])
        #expect(name == "SALES")
    }

    @Test("An unknown engine takes the lower case default")
    func unknownEngineTakesDefault() {
        let style = NewTableNameStyle.forDatabaseType(DatabaseType(rawValue: "SomeFuturePlugin"))
        #expect(style.casing == .lower)
        #expect(style.maximumByteLength == 63)
        #expect(style.reservedPrefix == nil)
    }

    /// Measured against the vendored SQLite: `CREATE TABLE "sqlite_backup"` fails with "object name
    /// reserved for internal use" quoted and unquoted, in any case, and `fetchTables` hides those
    /// objects so no collision check would catch it. A proposal carrying the prefix could never run.
    @Test("The SQLite family keeps its reserved prefix out of a proposal")
    func sqliteReservedPrefixIsBrokenUp() {
        for type in [DatabaseType.sqlite, .libsql, .turso, .cloudflareD1] {
            let style = NewTableNameStyle.forDatabaseType(type)
            #expect(style.reservedPrefix == "sqlite_")
            let name = NewTableNaming.suggestion(
                forFileNamed: "sqlite_backup.csv", style: style, avoiding: []
            )
            #expect(name == "t_sqlite_backup")
        }
    }

    @Test("A name that merely resembles the reserved prefix is left alone")
    func nearMissKeepsItsName() {
        let style = NewTableNameStyle.forDatabaseType(.sqlite)
        #expect(NewTableNaming.suggestion(forFileNamed: "sqlitex.csv", style: style, avoiding: []) == "sqlitex")
    }

    /// Engines outside the family have no such rule, so the prefix survives there.
    @Test("Other engines keep a name starting with the SQLite prefix")
    func otherEnginesKeepThePrefix() {
        #expect(suggestion("sqlite_backup.csv") == "sqlite_backup")
    }

    // MARK: - Length

    @Test("A long name is cut to the engine's byte limit")
    func longNameTruncates() {
        let name = suggestion(String(repeating: "a", count: 200) + ".csv")
        #expect(name.utf8.count == 63)
    }

    /// The limits are stated in bytes, so a multi-byte name has to be measured in bytes and cut
    /// between characters. A cut mid-scalar would not be a string at all.
    @Test("A multi-byte name is measured in bytes and cut between characters")
    func multiByteNameTruncatesOnBoundary() {
        let name = suggestion(String(repeating: "销", count: 40) + ".csv")
        #expect(name.utf8.count <= 63)
        #expect(name.count == 21)
        #expect(name.allSatisfy { $0 == "销" })
    }

    /// One grapheme can be wider than the whole cap, and cutting on a character boundary then
    /// yields nothing. An empty proposal would open the sheet on a blank-name warning.
    @Test("A single grapheme wider than the cap still proposes a usable name")
    func oversizedGraphemeFallsBack() {
        let grapheme = "a" + String(repeating: "\u{0301}", count: 40)
        let name = suggestion(grapheme + ".csv")
        #expect(!name.isEmpty)
        #expect(name.utf8.count <= 63)
    }

    @Test("A cut that lands on a separator does not leave one trailing")
    func truncationTrimsTrailingSeparator() {
        let stem = String(repeating: "a", count: 62) + " tail"
        #expect(suggestion(stem + ".csv") == String(repeating: "a", count: 62))
    }

    // MARK: - Collisions

    @Test("A free name is proposed unchanged")
    func freeNameIsProposedUnchanged() {
        #expect(suggestion("users.csv", taken: ["orders"]) == "users")
    }

    @Test("A taken name is disambiguated with a suffix")
    func takenNameGainsSuffix() {
        #expect(suggestion("users.csv", taken: ["users"]) == "users_2")
        #expect(suggestion("users.csv", taken: ["users", "users_2"]) == "users_3")
    }

    /// PostgreSQL folds an unquoted name and macOS MySQL compares one case-insensitively, so a
    /// suggestion differing only in case is a collision on both.
    @Test("Collisions compare case-insensitively")
    func collisionIsCaseInsensitive() {
        #expect(suggestion("Users.csv", taken: ["USERS"]) == "users_2")
    }

    @Test("A suffix keeps the whole name inside the byte limit")
    func suffixFitsInsideTheLimit() {
        let stem = String(repeating: "a", count: 100)
        let taken = [String(repeating: "a", count: 63)]
        let name = suggestion(stem + ".csv", taken: taken)
        #expect(name.utf8.count <= 63)
        #expect(name.hasSuffix("_2"))
    }

    // MARK: - Validating what the user typed

    @Test("An empty or whitespace name is blank")
    func blankNameIsReported() {
        #expect(NewTableNaming.problem(with: "", style: postgres, existingNames: []) == .blank)
        #expect(NewTableNaming.problem(with: "   ", style: postgres, existingNames: []) == .blank)
    }

    @Test("A free name has no problem")
    func freeNameHasNoProblem() {
        #expect(NewTableNaming.problem(with: "orders", style: postgres, existingNames: ["users"]) == nil)
    }

    @Test("A taken name is reported, whatever its case")
    func takenNameIsReported() {
        #expect(NewTableNaming.problem(with: "users", style: postgres, existingNames: ["users"]) == .nameTaken)
        #expect(NewTableNaming.problem(with: " Users ", style: postgres, existingNames: ["users"]) == .nameTaken)
    }

    /// The whole point of the optional: an unreachable catalog is an empty list, and calling every
    /// name free on that basis hands back the driver error this check exists to replace. It must
    /// not call a name taken either, which would block an import the engine would have accepted.
    @Test("An unknown catalog reports no collision and still catches a blank name")
    func unknownCatalogReportsNoCollision() {
        #expect(NewTableNaming.problem(with: "users", style: postgres, existingNames: nil) == nil)
        #expect(NewTableNaming.problem(with: "", style: postgres, existingNames: nil) == .blank)
    }

    /// The engine's rules bind whatever the user types, not just what was proposed. A name typed
    /// over the proposal used to reach `CREATE TABLE` unchecked and fail there.
    @Test("A typed name carrying the reserved prefix is refused")
    func typedReservedPrefixIsRefused() {
        let sqlite = NewTableNameStyle.forDatabaseType(.sqlite)
        #expect(
            NewTableNaming.problem(with: "sqlite_master", style: sqlite, existingNames: [])
                == .reservedPrefix("sqlite_")
        )
        #expect(NewTableNaming.problem(with: "sqlite_master", style: postgres, existingNames: []) == nil)
    }

    @Test("A typed name past the engine's limit is refused")
    func typedOverlongNameIsRefused() {
        let oracle = NewTableNameStyle.forDatabaseType(.oracle)
        let name = String(repeating: "a", count: 31)
        #expect(NewTableNaming.problem(with: name, style: oracle, existingNames: []) == .tooLong(maximumBytes: 30))
        #expect(NewTableNaming.problem(with: name, style: postgres, existingNames: []) == nil)
    }

    /// The limits are in bytes, so a multi-byte name hits them sooner than its character count says.
    @Test("Length is judged in bytes, not characters")
    func lengthIsJudgedInBytes() {
        let oracle = NewTableNameStyle.forDatabaseType(.oracle)
        #expect(
            NewTableNaming.problem(with: String(repeating: "销", count: 11), style: oracle, existingNames: [])
                == .tooLong(maximumBytes: 30)
        )
        #expect(NewTableNaming.problem(with: String(repeating: "销", count: 10), style: oracle, existingNames: []) == nil)
    }
}
