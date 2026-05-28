//
//  PostgreSQLPluginDriver+Spatial.swift
//  PostgreSQLDriverPlugin
//
//  PostGIS rendering support. Geometry and geography values arrive from libpq as
//  raw EWKB hex (e.g. "0101000020E6100000..."). To surface them as readable WKT
//  with SRID, we probe pg_type for the dynamic PostGIS OIDs at connect time and,
//  when a result set contains spatial columns, re-execute the query wrapped in a
//  projection that applies ST_AsEWKT to each spatial column.
//

import Foundation

enum PostGISSpatialRewrite {
    static let probeQuery = "SELECT oid, typname FROM pg_type WHERE typname IN ('geometry', 'geography')"

    static func quoteIdentifier(_ ident: String) -> String {
        "\"\(ident.replacingOccurrences(of: "\"", with: "\"\""))\""
    }

    static func buildWrappedQuery(
        originalQuery: String,
        columns: [String],
        spatialIndices: Set<Int>
    ) -> String {
        var trimmed = originalQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasSuffix(";") {
            trimmed = String(trimmed.dropLast()).trimmingCharacters(in: .whitespacesAndNewlines)
        }

        let projections = columns.enumerated().map { index, name -> String in
            let quoted = quoteIdentifier(name)
            if spatialIndices.contains(index) {
                return "ST_AsEWKT(\(quoted)) AS \(quoted)"
            }
            return quoted
        }

        return "SELECT \(projections.joined(separator: ", ")) FROM (\(trimmed)) AS _tp_rewrite"
    }

    static func isSafeToWrap(query: String, columns: [String]) -> Bool {
        guard hasUniqueColumnNames(columns) else { return false }
        guard startsWithSelectWithOrValues(query) else { return false }
        return !hasTopLevelStatementSeparator(query)
    }

    static func hasUniqueColumnNames(_ columns: [String]) -> Bool {
        Set(columns).count == columns.count
    }

    static func startsWithSelectWithOrValues(_ query: String) -> Bool {
        let chars = Array(query)
        var i = 0
        while i < chars.count {
            let c = chars[i]
            if c.isWhitespace {
                i += 1
                continue
            }
            if c == "-", i + 1 < chars.count, chars[i + 1] == "-" {
                while i < chars.count, chars[i] != "\n" { i += 1 }
                continue
            }
            if c == "/", i + 1 < chars.count, chars[i + 1] == "*" {
                i = skipBlockComment(chars, startingAt: i)
                continue
            }
            break
        }

        var ident = ""
        while i < chars.count, chars[i].isLetter {
            ident.append(chars[i])
            i += 1
        }
        let upper = ident.uppercased()
        return upper == "SELECT" || upper == "WITH" || upper == "VALUES"
    }

    static func hasTopLevelStatementSeparator(_ query: String) -> Bool {
        let chars = Array(query)
        var i = 0
        var sawTerminator = false
        while i < chars.count {
            let c = chars[i]

            if c == "-", i + 1 < chars.count, chars[i + 1] == "-" {
                while i < chars.count, chars[i] != "\n" { i += 1 }
                continue
            }
            if c == "/", i + 1 < chars.count, chars[i + 1] == "*" {
                i = skipBlockComment(chars, startingAt: i)
                continue
            }
            if c == "'" {
                i = skipSingleQuoted(chars, startingAt: i)
                continue
            }
            if c == "\"" {
                i = skipDoubleQuoted(chars, startingAt: i)
                continue
            }
            if c == "$", let endOfDollar = skipDollarQuoted(chars, startingAt: i) {
                i = endOfDollar
                continue
            }

            if c == ";" {
                sawTerminator = true
                i += 1
                continue
            }

            if sawTerminator, !c.isWhitespace {
                return true
            }

            i += 1
        }
        return false
    }

    private static func skipBlockComment(_ chars: [Character], startingAt start: Int) -> Int {
        var i = start + 2
        var depth = 1
        while i < chars.count, depth > 0 {
            if chars[i] == "/", i + 1 < chars.count, chars[i + 1] == "*" {
                depth += 1
                i += 2
            } else if chars[i] == "*", i + 1 < chars.count, chars[i + 1] == "/" {
                depth -= 1
                i += 2
            } else {
                i += 1
            }
        }
        return i
    }

    private static func skipSingleQuoted(_ chars: [Character], startingAt start: Int) -> Int {
        var i = start + 1
        while i < chars.count {
            if chars[i] == "'" {
                if i + 1 < chars.count, chars[i + 1] == "'" {
                    i += 2
                } else {
                    return i + 1
                }
            } else {
                i += 1
            }
        }
        return i
    }

    private static func skipDoubleQuoted(_ chars: [Character], startingAt start: Int) -> Int {
        var i = start + 1
        while i < chars.count {
            if chars[i] == "\"" {
                if i + 1 < chars.count, chars[i + 1] == "\"" {
                    i += 2
                } else {
                    return i + 1
                }
            } else {
                i += 1
            }
        }
        return i
    }

    private static func skipDollarQuoted(_ chars: [Character], startingAt start: Int) -> Int? {
        var tagEnd = start + 1
        while tagEnd < chars.count {
            let ch = chars[tagEnd]
            if ch == "$" { break }
            let isFirst = tagEnd == start + 1
            let validFirst = ch.isLetter || ch == "_"
            let validRest = validFirst || ch.isNumber
            if isFirst ? !validFirst : !validRest {
                return nil
            }
            tagEnd += 1
        }
        guard tagEnd < chars.count, chars[tagEnd] == "$" else { return nil }

        let tag = Array(chars[start...tagEnd])
        var i = tagEnd + 1
        while i + tag.count <= chars.count {
            if chars[i] == "$" {
                var matches = true
                for j in 0..<tag.count where chars[i + j] != tag[j] {
                    matches = false
                    break
                }
                if matches {
                    return i + tag.count
                }
            }
            i += 1
        }
        return chars.count
    }
}
