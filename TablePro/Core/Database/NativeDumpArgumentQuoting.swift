//
//  NativeDumpArgumentQuoting.swift
//  TablePro
//

import Foundation

/// Turning a picked object name into the argument its tool actually matches on.
///
/// Two of the tools do not take a name at all. `pg_dump -t` takes a `psql` `\d` pattern, and
/// `sqlite3 .dump` takes a `LIKE` pattern, so a name handed over raw is a filter that happens to
/// look right on lowercase names with no punctuation and silently misfires on everything else.
/// Both were measured against the shipped binaries rather than read off a manual.
enum NativeDumpArgumentQuoting {
    /// The `-t` value for one table.
    ///
    /// Measured with pg_dump 17.11: `-t 'app.Orders'`, `-t 'order.item'` and `-t 'app.t[1]'` all
    /// exit with "no matching tables were found", because the pattern folds to lower case, splits
    /// on the first dot and reads `[` as a character class. `-t '"app"."Orders"'`,
    /// `-t '"app"."order.item"'`, `-t '"app"."t[1]"'` and `-t '"app"."we""ird"'` all match exactly
    /// one table. Double quotes stop the folding and every metacharacter, and an embedded quote is
    /// written twice, which is the same rule SQL identifiers follow.
    static func postgresTablePattern(_ object: NativeDumpObject) -> String {
        let table = quotedPatternPart(object.name)
        guard let schema = object.schema else { return table }
        return "\(quotedPatternPart(schema)).\(table)"
    }

    private static func quotedPatternPart(_ value: String) -> String {
        "\"\(value.replacingOccurrences(of: "\"", with: "\"\""))\""
    }

    /// The whole `.dump` invocation for a narrowed SQLite backup, as ONE process argument.
    ///
    /// One argument, not one per name, and this is a security boundary rather than a style choice.
    /// `sqlite3` parses its command line itself: every argument is either an option or a command,
    /// so a table named `-cmd` followed by one named `.shell touch /tmp/x` is two arguments that
    /// run an arbitrary shell command, and `-` and `.` are both legal in a quoted SQLite
    /// identifier. Measured with sqlite3 3.54.0: as separate arguments the payload executed; inside
    /// one quoted `.dump` command it is inert.
    ///
    /// It is also the only shape that filters at all. Measured: `sqlite3 db .dump t1` prints
    /// `Parse error ... near "t1"` and then dumps the WHOLE database, because `t1` is a second
    /// command rather than an argument to the first.
    ///
    /// Two layers of escaping, in this order, both measured. Each name is a `LIKE` pattern over
    /// `sqlite_master.name`, so `\`, `%` and `_` are escaped with `\` first, or `.dump user_data`
    /// also dumps `userXdata`. The dot-command tokenizer then reads `\` and `"` inside a
    /// double-quoted token, so both are escaped again on top: `back\slash` ends up as
    /// `"back\\\\slash"`, which is what matched.
    static func sqliteDumpCommand(names: [String]) -> String {
        guard !names.isEmpty else { return ".dump" }
        return ([".dump"] + names.map(sqliteDumpToken)).joined(separator: " ")
    }

    static func sqliteDumpToken(_ name: String) -> String {
        let pattern = name
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "%", with: "\\%")
            .replacingOccurrences(of: "_", with: "\\_")
        let tokenized = pattern
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        return "\"\(tokenized)\""
    }

    /// Every object `sqlite3 .dump` needs to be told about to reproduce one table.
    ///
    /// Measured: `.dump t1` writes `CREATE TABLE t1` and nothing else, dropping the table's index
    /// and its trigger. Naming them alongside it brings all three back. `sqlite_master.tbl_name`
    /// is what relates them.
    static func sqliteDependentsQuery() -> String {
        "SELECT name FROM sqlite_master WHERE tbl_name = ? AND name IS NOT NULL"
    }

    /// The `--nsInclude` value for one collection, which is a `database.collection` namespace.
    ///
    /// `mongodump` reads `*` in a namespace as a wildcard and offers no escape for it, so a
    /// collection whose name carries one widens the dump. MongoDB permits `*` in a collection name,
    /// so the sheet says which collections a run actually covered rather than claiming the
    /// selection was exact.
    static func mongoNamespace(database: String, collection: String) -> String {
        "\(database).\(collection)"
    }
}
