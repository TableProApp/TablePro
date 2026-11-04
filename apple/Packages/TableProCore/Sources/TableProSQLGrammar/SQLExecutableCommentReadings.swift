import Foundation

/// The texts a MySQL, MariaDB or TiDB server may run from one text, the text itself first.
///
/// A `/*!` body runs as code when it has no version or one not above the server's. A higher version is skipped as bytes
/// to the first `*/` past one nested `/* */`, and MariaDB also skips `/*!50700` to `/*!99999`. MySQL reads MariaDB's
/// `/*M!` and TiDB's `/*T!` as plain comments, and every server reads `/*m!` as one. A text can mix run and skipped
/// comments, so there is one text per version threshold per server family. Measured on MySQL 8.0 and 8.4, MariaDB 10.11
/// and 11.4 and TiDB 8.5 by `scripts/probes/check-mysql-executable-comments.sh`.
public enum SQLExecutableCommentReadings {
    public enum Family: Sendable, Hashable, CaseIterable {
        /// MySQL before 8.1: a version is five digits, and a sixth digit is the body's.
        case mySQL5
        /// MySQL 8.1 and later: a sixth digit belongs to the version when whitespace follows it.
        case mySQL81
        /// MariaDB: a sixth digit always belongs to the version.
        case mariaDB
        /// A MariaDB Galera node, which also runs `/*!99997` (`sql_lex.cc`, not measured).
        case galera
        /// A Galera node built on MySQL before 8.1, such as Percona XtraDB Cluster: the same wsrep patch runs
        /// `/*!99997` there too, and everything else reads as `mySQL5` (`sql_lex.cc`, not measured).
        case mySQL5Galera
        /// A Galera node built on MySQL 8.1 or later, which otherwise reads as `mySQL81`.
        case mySQL81Galera
        /// TiDB: `/*!` runs whatever its version, `/*T!` runs, and `/*T![feature]` reads as plain when TiDB lacks it.
        case tiDB
        /// OceanBase rereads a statement that fails with every `/*!` as a plain comment (`ob_parser.cpp`, not measured).
        case oceanBase
    }

    public struct Server: Sendable, Hashable {
        public let family: Family
        public let version: Int

        public init(family: Family, version: Int) {
            self.family = family
            self.version = version
        }
    }

    /// More distinct versions than a gate reads one by one: a text that sets them is read as the worst statement.
    public static let maximumVersions = 32

    /// The texts `grammar` reads, or nil when `text` sets more than ``maximumVersions`` versions. Lazy, so a gate that
    /// has its answer from the first texts never rewrites the rest.
    public static func texts(of text: String, grammar: SQLLexicalGrammar) -> Texts? {
        // By UTF-16 unit: a Prepend scalar such as U+0600 joins the `/` after it into one Character.
        let units = text as NSString
        let holdsOpener = ["/*!", "/*M!", "/*T!"].contains {
            units.range(of: $0, options: .literal).location != NSNotFound
        }
        guard grammar.contains(.executableComments), holdsOpener else {
            return Texts(text: text, source: nil, grammar: grammar)
        }
        let source = Source(text)
        guard source.distinctVersions.count <= maximumVersions else { return nil }
        return Texts(text: text, source: source, grammar: grammar)
    }

    public static func text(of text: String, grammar: SQLLexicalGrammar, on server: Server) -> String {
        let source = Source(text)
        return source.rewritten(grammar: grammar) { $0.decision(on: server, in: source.units) }
    }

    /// Whether `text` holds an executable comment where `grammar` reads code.
    public static func holdsExecutableComment(_ text: String, grammar: SQLLexicalGrammar) -> Bool {
        guard grammar.contains(.executableComments) else { return false }
        let source = text as NSString
        var index = 0
        while index < source.length {
            guard let span = SQLNonCodeSpan.span(at: index, in: source, grammar: grammar) else {
                index += 1
                continue
            }
            if span.kind == .executableComment { return true }
            index = max(span.end, index + 1)
        }
        return false
    }

    public struct Texts: Sequence {
        fileprivate let text: String
        fileprivate let source: Source?
        fileprivate let grammar: SQLLexicalGrammar

        public func makeIterator() -> Iterator {
            Iterator(texts: self)
        }
    }

    public struct Iterator: IteratorProtocol {
        private let texts: Texts
        private var returnedText = false
        private var deciders: [Source.Decider]?
        private var nextSet = 0
        private var seen: Set<String> = []

        fileprivate init(texts: Texts) {
            self.texts = texts
        }

        public mutating func next() -> String? {
            guard returnedText else {
                returnedText = true
                return texts.text
            }
            guard let source = texts.source else { return nil }
            if deciders == nil {
                deciders = source.deciders(grammar: texts.grammar)
                seen.insert(texts.text)
            }
            guard let deciders else { return nil }
            while nextSet < deciders.count {
                let decide = deciders[nextSet]
                nextSet += 1
                let rewritten = source.rewritten(grammar: texts.grammar, deciding: decide)
                if seen.insert(rewritten).inserted { return rewritten }
            }
            return nil
        }
    }
}

extension SQLExecutableCommentReadings {
    enum Decision: Hashable {
        case runs(openerLength: Int)
        case skipped
        case plain
    }

    fileprivate enum Marker: Hashable {
        case bang
        case mariaDB
        case tiDB
    }

    // What an opener's decision depends on: its marker, its length, and the digits a server can read as its version.
    fileprivate struct OpenerKind: Hashable {
        let marker: Marker
        let markerLength: Int
        let digits: Int
        let followedByWhitespace: Bool
        let leadingDigits: Int

        init(_ opener: Opener, in units: [UInt16]) {
            marker = opener.marker
            markerLength = opener.markerLength
            digits = min(opener.digits, 7)
            followedByWhitespace = opener.followedByWhitespace
            let start = opener.offset + opener.markerLength
            leadingDigits = units[start..<(start + min(opener.digits, 6))]
                .reduce(0) { $0 * 10 + Int($1 - Source.digitZero) }
        }
    }

    fileprivate struct Opener {
        let offset: Int
        let marker: Marker
        let markerLength: Int
        let digits: Int
        let followedByWhitespace: Bool

        var isMariaDBMarker: Bool {
            marker == .mariaDB
        }

        func version(for family: Family, in units: [UInt16]) -> (value: Int, length: Int)? {
            guard digits >= 5, marker != .tiDB else { return nil }
            let length: Int
            switch family {
            case .mySQL5, .mySQL5Galera, .tiDB:
                length = 5
            case .mySQL81, .mySQL81Galera:
                length = digits == 6 && followedByWhitespace ? 6 : 5
            case .mariaDB, .galera:
                length = min(digits, 6)
            case .oceanBase:
                return nil
            }
            let start = offset + markerLength
            let value = units[start..<(start + length)].reduce(0) { $0 * 10 + Int($1 - Source.digitZero) }
            return (value, length)
        }

        func decision(on server: Server, in units: [UInt16]) -> Decision {
            switch (marker, server.family) {
            case (_, .oceanBase), (.tiDB, .mySQL5), (.tiDB, .mySQL81), (.tiDB, .mariaDB), (.tiDB, .galera),
                 (.tiDB, .mySQL5Galera), (.tiDB, .mySQL81Galera),
                 (.mariaDB, .mySQL5), (.mariaDB, .mySQL81), (.mariaDB, .tiDB),
                 (.mariaDB, .mySQL5Galera), (.mariaDB, .mySQL81Galera):
                return .plain
            case (.tiDB, .tiDB):
                return .runs(openerLength: markerLength)
            default:
                break
            }
            guard let version = version(for: server.family, in: units) else {
                return .runs(openerLength: markerLength)
            }
            let runs: Bool
            switch server.family {
            case .mySQL5, .mySQL81:
                runs = version.value <= server.version
            case .mySQL5Galera, .mySQL81Galera:
                runs = version.value <= server.version || version.value == 99_997
            case .tiDB:
                runs = true
            case .mariaDB, .galera:
                let mySQLOnly = !isMariaDBMarker && (50_700...99_999).contains(version.value)
                runs = (version.value <= server.version && !mySQLOnly)
                    || (server.family == .galera && !isMariaDBMarker && version.value == 99_997)
            case .oceanBase:
                runs = false
            }
            return runs ? .runs(openerLength: markerLength + version.length) : .skipped
        }
    }

    fileprivate struct Source {
        static let digitZero = UInt16(UnicodeScalar("0").value)
        static let digitNine = UInt16(UnicodeScalar("9").value)
        static let exclamationMark = UInt16(UnicodeScalar("!").value)
        static let capitalM = UInt16(UnicodeScalar("M").value)
        static let capitalT = UInt16(UnicodeScalar("T").value)
        static let openBracket = UInt16(UnicodeScalar("[").value)
        static let closeBracket = UInt16(UnicodeScalar("]").value)
        static let comma = UInt16(UnicodeScalar(",").value)
        // MySQL 8.1 is the first version to read a sixth digit.
        static let firstSixDigitMySQL = 80_100

        let text: NSString
        let units: [UInt16]
        let openers: [Int: Opener]
        let distinctVersions: Set<Int>

        init(_ string: String) {
            text = string as NSString
            units = Array(string.utf16)
            openers = Self.openers(in: units)
            var versions: Set<Int> = []
            for opener in openers.values {
                for family in Family.allCases {
                    if let version = opener.version(for: family, in: units) {
                        versions.insert(version.value)
                    }
                }
            }
            distinctVersions = versions
        }

        static func openers(in units: [UInt16]) -> [Int: Opener] {
            var found: [Int: Opener] = [:]
            var index = 0
            while index + 2 < units.count {
                defer { index += 1 }
                guard units[index] == SqlLexer.slash, units[index + 1] == SqlLexer.star else { continue }
                var cursor = index + 2
                let marker: Marker
                switch units[cursor] {
                case capitalM: marker = .mariaDB
                case capitalT: marker = .tiDB
                default: marker = .bang
                }
                if marker != .bang { cursor += 1 }
                guard cursor < units.count, units[cursor] == exclamationMark else { continue }
                cursor += 1
                // TiDB reads the features a `/*T![a,b]` names as part of the opener.
                if marker == .tiDB, cursor < units.count, units[cursor] == openBracket,
                   let close = featureListEnd(in: units, from: cursor + 1) {
                    cursor = close + 1
                }
                let markerLength = cursor - index
                var digits = 0
                while cursor + digits < units.count, isDigit(units[cursor + digits]) {
                    digits += 1
                }
                let after = cursor + digits
                found[index] = Opener(
                    offset: index,
                    marker: marker,
                    markerLength: markerLength,
                    digits: digits,
                    followedByWhitespace: after < units.count && isWhitespace(units[after])
                )
            }
            return found
        }

        // A feature list holds names and commas, so the search stops at anything else and stays linear.
        static func featureListEnd(in units: [UInt16], from start: Int) -> Int? {
            var index = start
            while index < units.count {
                let unit = units[index]
                if unit == closeBracket { return index }
                let continues = SqlDollarQuote.isIdentifierPart(unit) || unit == comma || unit == SqlLexer.space
                guard continues else { return nil }
                index += 1
            }
            return nil
        }

        static func isDigit(_ unit: UInt16) -> Bool {
            unit >= digitZero && unit <= digitNine
        }

        // my_isspace: space, tab, line feed, vertical tab, form feed, carriage return.
        static func isWhitespace(_ unit: UInt16) -> Bool {
            unit == 0x20 || (0x09...0x0D).contains(unit)
        }

        // Two servers that decide every kind of opener alike run the same text. Openers of one kind decide alike, so
        // a text with thousands of them costs one decision per kind.
        func distinctServers() -> [Server] {
            guard !openers.isEmpty else { return [] }
            var kinds: [OpenerKind: Opener] = [:]
            for opener in openers.values {
                kinds[OpenerKind(opener, in: units)] = opener
            }
            let representatives = Array(kinds.values)
            var servers: [Server] = []
            var signatures: Set<[Decision]> = []
            for family in Family.allCases {
                for version in thresholds(for: family, openers: representatives) {
                    let server = Server(family: family, version: version)
                    let signature = representatives.map { $0.decision(on: server, in: units) }
                    if signatures.insert(signature).inserted {
                        servers.append(server)
                    }
                }
            }
            return servers
        }

        private func thresholds(for family: Family, openers: [Opener]) -> [Int] {
            let versions = Set(openers.compactMap { $0.version(for: family, in: units)?.value })
            switch family {
            case .mySQL5:
                return [0] + versions.filter { $0 < Self.firstSixDigitMySQL }.sorted()
            case .mySQL81:
                return [Self.firstSixDigitMySQL] + versions.filter { $0 > Self.firstSixDigitMySQL }.sorted()
            case .mySQL5Galera:
                guard versions.contains(99_997) else { return [] }
                return thresholds(for: .mySQL5, openers: openers)
            case .mySQL81Galera:
                guard versions.contains(99_997) else { return [] }
                return thresholds(for: .mySQL81, openers: openers)
            case .mariaDB:
                return [0] + versions.sorted()
            case .galera:
                guard versions.contains(99_997) else { return [] }
                return [0] + versions.sorted()
            case .tiDB:
                return openers.contains { $0.marker == .tiDB } ? [0] : []
            case .oceanBase:
                return [0]
            }
        }

        typealias Decider = (Opener) -> Decision

        func deciders(grammar: SQLLexicalGrammar) -> [Decider] {
            let servers = distinctServers()
            if let statementwise = statementwiseDeciders(servers: servers, grammar: grammar) {
                return statementwise
            }
            return servers.map { server in { [units] opener in opener.decision(on: server, in: units) } }
        }

        static let semicolon = UInt16(UnicodeScalar(";").value)
        static let boundaryShapingFacts: SQLLexicalGrammar = [
            .unterminatedStatements, .batchSeparatorLines, .plsqlBlocks, .cqlBatches, .slashLineTerminators,
            .sqlScriptBlocks, .terminatedMergeStatements,
        ]

        // A dump holds a dozen versions, one text per threshold, and every text is scanned whole. When no comment can
        // move a statement boundary, a statement only needs the readings of its own comments, so a few texts that each
        // take one of them per statement hold every statement every server runs. That needs each comment to end at
        // the same place however it is read and to hold no `;` or line break, and no statement to keep a `;` inside a
        // BEGIN or a CASE. Otherwise nil, and every server's text is read.
        func statementwiseDeciders(servers: [Server], grammar: SQLLexicalGrammar) -> [Decider]? {
            guard let first = servers.first, grammar.isDisjoint(with: Self.boundaryShapingFacts),
                  text.range(of: "DELIMITER", options: .caseInsensitive).location == NSNotFound
            else { return nil }
            let plain = grammar.subtracting(.executableComments)
            var sitesByStatement: [Int: [Int]] = [:]
            var statement = 0
            var index = 0
            while index < units.count {
                let unit = units[index]
                if unit == SqlLexer.slash, index + 1 < units.count, units[index + 1] == SqlLexer.star {
                    if let opener = openers[index] {
                        guard let end = stableEnd(of: opener, servers: servers, plain: plain, grammar: grammar) else {
                            return nil
                        }
                        sitesByStatement[statement, default: []].append(index)
                        index = end
                    } else {
                        index = plainCommentEnd(at: index, grammar: grammar)
                    }
                    continue
                }
                guard let next = codeStep(at: index, plain: plain) else { return nil }
                if unit == Self.semicolon { statement += 1 }
                index = next
            }
            var readings: [Int: [[Decision]]] = [:]
            for (statement, sites) in sitesByStatement {
                var seen: Set<[Decision]> = []
                for server in servers {
                    let vector = sites.map { openers[$0]?.decision(on: server, in: units) ?? .skipped }
                    if seen.insert(vector).inserted {
                        readings[statement, default: []].append(vector)
                    }
                }
            }
            let count = readings.values.map(\.count).max() ?? 0
            return (0..<count).map { pick in
                var decisions: [Int: Decision] = [:]
                for (statement, sites) in sitesByStatement {
                    guard let vectors = readings[statement] else { continue }
                    let vector = vectors[min(pick, vectors.count - 1)]
                    for (site, offset) in sites.enumerated() {
                        decisions[offset] = vector[site]
                    }
                }
                return { [units] opener in decisions[opener.offset] ?? opener.decision(on: first, in: units) }
            }
        }

        private func stableEnd(
            of opener: Opener,
            servers: [Server],
            plain: SQLLexicalGrammar,
            grammar: SQLLexicalGrammar
        ) -> Int? {
            var end: Int?
            for decision in Set(servers.map { opener.decision(on: $0, in: units) }) {
                let candidate: Int?
                switch decision {
                case .runs(let openerLength):
                    candidate = runEnd(from: opener.offset + openerLength, plain: plain, grammar: grammar)
                case .skipped:
                    candidate = consumeComment(from: opener.offset + 2, nestingAllowed: 1)
                case .plain:
                    candidate = consumeComment(from: opener.offset + 2, nestingAllowed: 0)
                }
                guard let candidate, end == nil || end == candidate else { return nil }
                end = candidate
            }
            return end
        }

        // Where a run body's closing `*/` ends it, or nil when the body holds what could move a statement boundary.
        private func runEnd(from start: Int, plain: SQLLexicalGrammar, grammar: SQLLexicalGrammar) -> Int? {
            var index = start
            while index < units.count {
                let unit = units[index]
                let next: UInt16 = index + 1 < units.count ? units[index + 1] : 0
                if unit == SqlLexer.star, next == SqlLexer.slash { return index + 2 }
                if unit == Self.semicolon || unit == SqlLexer.newline { return nil }
                if unit == SqlLexer.slash, next == SqlLexer.star {
                    guard openers[index] == nil else { return nil }
                    index = plainCommentEnd(at: index, grammar: grammar)
                    continue
                }
                guard let step = codeStep(at: index, plain: plain) else { return nil }
                index = step
            }
            return nil
        }

        // Past one literal, line comment, word or unit of code; nil at a word that can open a block a `;` stays in.
        // Words are read as the statement scanner reads them, so `1BEGIN` holds the BEGIN it sees.
        private func codeStep(at index: Int, plain: SQLLexicalGrammar) -> Int? {
            if let span = SQLNonCodeSpan.span(at: index, in: text, grammar: plain) {
                return max(span.end, index + 1)
            }
            guard SqlBlockStructure.startsWord(text, at: index, length: units.count, grammar: plain) else {
                return index + 1
            }
            let word = SqlBlockStructure.readKeyword(text, at: index, length: units.count, grammar: plain)
            return word.text == "BEGIN" || word.text == "CASE" ? nil : word.end
        }

        private func plainCommentEnd(at index: Int, grammar: SQLLexicalGrammar) -> Int {
            grammar.contains(.nestedBlockComments)
                ? SqlLexer.skipNestedBlockComment(text, from: index, length: units.count).next
                : SqlLexer.skipBlockComment(text, from: index, length: units.count).next
        }

        func rewritten(grammar: SQLLexicalGrammar, deciding decide: (Opener) -> Decision) -> String {
            guard !openers.isEmpty else { return text as String }
            let plain = grammar.subtracting(.executableComments)
            let length = units.count
            var output = units
            var index = 0
            var insideRunComment = false
            while index < length {
                let unit = units[index]
                let next: UInt16 = index + 1 < length ? units[index + 1] : 0
                if insideRunComment, unit == SqlLexer.star, next == SqlLexer.slash {
                    blank(&output, from: index, to: index + 2)
                    insideRunComment = false
                    index += 2
                    continue
                }
                if unit == SqlLexer.slash, next == SqlLexer.star {
                    switch openers[index].map(decide) {
                    case .runs(let openerLength):
                        blank(&output, from: index, to: index + openerLength)
                        insideRunComment = true
                        index += openerLength
                    case .skipped:
                        let end = consumeComment(from: index + 2, nestingAllowed: 1)
                        blank(&output, from: index, to: end)
                        index = end
                    case .plain:
                        let end = consumeComment(from: index + 2, nestingAllowed: 0)
                        blank(&output, from: index, to: end)
                        index = end
                    case nil:
                        index = plainCommentEnd(at: index, grammar: grammar)
                    }
                    continue
                }
                // A plain comment stays: every reader lexes it as the server does.
                if let span = SQLNonCodeSpan.span(at: index, in: text, grammar: plain) {
                    index = max(span.end, index + 1)
                    continue
                }
                index += 1
            }
            return String(utf16CodeUnits: output, count: length)
        }

        // MySQL's consume_comment: the first `*/` ends the comment, after `nestingAllowed` levels of `/* */` inside it.
        private func consumeComment(from start: Int, nestingAllowed: Int) -> Int {
            var cursor = start
            while cursor < units.count {
                let unit = units[cursor]
                cursor += 1
                let next: UInt16 = cursor < units.count ? units[cursor] : 0
                if nestingAllowed > 0, unit == SqlLexer.slash, next == SqlLexer.star {
                    cursor = consumeComment(from: cursor + 1, nestingAllowed: nestingAllowed - 1)
                    continue
                }
                if unit == SqlLexer.star, next == SqlLexer.slash {
                    return cursor + 1
                }
            }
            return units.count
        }

        // A comment is a token boundary to the server, so `--/*!99999 x */` is two minus signs. Blanking it whole
        // would turn the dashes into a `-- ` comment that hides the rest of the line, so its first unit stays.
        private func blank(_ output: inout [UInt16], from start: Int, to end: Int) {
            let followsDashes = start >= 2 && units[start - 1] == SqlLexer.dash && units[start - 2] == SqlLexer.dash
            let first = followsDashes ? start + 1 : start
            guard first < min(end, output.count) else { return }
            for offset in first..<min(end, output.count) where output[offset] != SqlLexer.newline {
                output[offset] = SqlLexer.space
            }
        }
    }
}
