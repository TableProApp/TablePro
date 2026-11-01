import Foundation

/// InfluxDB 2 reads Flux as well as InfluxQL. The SQL reading tiers `from(bucket: ...)` as an unknown
/// statement, so a read-only connection would refuse every Flux read. A Flux script only reads unless
/// it calls a function that writes points or sends data out; InfluxQL and SQL fall through to the SQL
/// reading.
extension QueryClassifier {
    static func influxDBClassification(_ sql: String) -> QueryClassification? {
        let code = fluxCode(sql)
        switch languageHint(sql) {
        case "flux": break
        case "influxql", "sql": return nil
        default: guard looksLikeFlux(code) else { return nil }
        }
        let writes = fluxWritingCalls.contains { code.range(of: $0, options: .regularExpression) != nil }
        let withStrings = fluxCode(sql, keepingStrings: true)
        let reachesOutside = fluxOutsideCalls.contains { code.range(of: $0, options: .regularExpression) != nil }
            || withStrings.range(of: fluxOutsideImport, options: .regularExpression) != nil
        return QueryClassification(tier: writes ? .write : .safe, reachesFilesystemOrExecutesCode: reachesOutside)
    }

    /// `to()` and `wideTo()` write points, `experimental.to()` too; a `sql.to()` writes to another database.
    /// Any mention counts, not only a call, so `w = to` followed by `w(bucket: ...)` is a write too.
    /// A record field or parameter named `to:` is not one.
    private static let fluxWritingCalls = [#"\b(?:to|wideTo)\b(?!\s*:)"#]

    /// Packages that reach a network service or the server's files rather than the bucket. The import
    /// path is matched as well as the member, since `import h "http"` renames the package.
    private static let fluxOutsideCalls = [
        #"\b(?:http|requests|sql|slack|pagerduty|mqtt|socket|sensu|telegram|opsgenie|victorops|discord|teams)\."#,
        #"\bcsv\.from\s*\(\s*file\s*:"#,
    ]

    private static let fluxOutsideImport =
        #"\bimport\s+(?:\w+\s+)?"(?:[^"]*/)?(?:http|requests|sql|slack|pagerduty|mqtt|socket|sensu|telegram|opsgenie|victorops|discord|teams)""#

    /// The driver sends a statement whose first line is `-- influxql`, `-- sql` or `// flux` in that
    /// language whatever the rest looks like, so the classifier reads it the same way.
    private static func languageHint(_ sql: String) -> String? {
        let firstLine = sql.trimmingCharacters(in: .whitespacesAndNewlines)
            .split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: false).first ?? ""
        guard firstLine.hasPrefix("--") || firstLine.hasPrefix("//") else { return nil }
        return firstLine.dropFirst(2).trimmingCharacters(in: .whitespaces).lowercased()
    }

    private static func looksLikeFlux(_ code: String) -> Bool {
        if code.contains("|>") { return true }
        let lowered = code.lowercased()
        return ["from(", "import ", "buckets(", "option "].contains { lowered.hasPrefix($0) }
    }

    /// The text without `//` line comments and, unless `keepingStrings`, with string contents blanked,
    /// so a comment or a string that spells `to(` neither writes nor hides a call.
    static func fluxCode(_ sql: String, keepingStrings: Bool = false) -> String {
        var code = ""
        var inString = false
        var inComment = false
        var escaped = false
        var previous: Character?
        for character in sql {
            if inComment {
                if character == "\n" {
                    inComment = false
                    code.append(character)
                }
                previous = character
                continue
            }
            if inString {
                if escaped {
                    escaped = false
                } else if character == "\\" {
                    escaped = true
                } else if character == "\"" {
                    inString = false
                }
                if keepingStrings || !inString {
                    code.append(character)
                }
                previous = character
                continue
            }
            if character == "/", previous == "/" {
                code.removeLast()
                inComment = true
            } else if character == "\"" {
                inString = true
                code.append(character)
            } else {
                code.append(character)
            }
            previous = character
        }
        return code.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
