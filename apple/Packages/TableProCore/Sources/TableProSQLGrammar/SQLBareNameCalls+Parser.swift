import Foundation

extension SQLBareNameCalls {
    // One query's blocks: each SELECT, the tables it reads and the names it holds. A shape it cannot read, such as a
    // `WITH` that is not a list of named queries, counts as a call.
    struct Parser {
        typealias Block = SQLBareNameBlock

        private struct CommonTable {
            var block: Int?
            var columns: [String]?
        }

        private enum Clause {
            case from
            case orderBy
            case other
        }

        private enum FromState {
            case expectTable
            case afterTable
            case afterAlias
        }

        private let code: StatementCode
        private let grammar: SQLLexicalGrammar
        private let reserved: Set<String>
        private let tokens: [TSQLTokens.Token]
        private var closing: [Int: Int] = [:]
        private(set) var blocks: [Block] = []
        private(set) var callsOutright = false

        init(_ code: StatementCode, grammar: SQLLexicalGrammar, reserved: Set<String>) {
            self.code = code
            self.grammar = grammar
            self.reserved = reserved
            tokens = code.tokens
            var open: [Int] = []
            for (index, token) in tokens.enumerated() {
                if token.kind == .open {
                    open.append(index)
                } else if token.kind == .close, let start = open.popLast() {
                    closing[start] = index
                }
            }
        }

        // A query tab hands the gate its statements joined by line breaks, which Oracle does not split on, so a SELECT
        // standing where a clause would is read as the next query.
        // A write is refused before this is asked, so only queries and EXPLAIN PLAN reach it.
        mutating func parse() {
            let end = (tokens.lastIndex { $0.kind != .terminator }).map { $0 + 1 } ?? 0
            var index = 0
            while index < end {
                let token = tokens[index]
                guard token.depth == 0 else {
                    index += 1
                    continue
                }
                if token.word == "EXPLAIN" {
                    // EXPLAIN PLAN plans its statement without running it, so the statement is read and dropped.
                    guard let plan = (index..<end).first(where: { tokens[$0].depth == 0 && word(at: $0) == "FOR" }) else {
                        return resolveChains()
                    }
                    var planned = self
                    index = max(plan + 1, planned.queryExpression((plan + 1)..<end, parent: nil, commonTables: [:]).end)
                    continue
                }
                // A `WITH FUNCTION` declares PL/SQL its query then calls by a bare name.
                if token.word == "WITH", word(at: index + 1) == "FUNCTION" || word(at: index + 1) == "PROCEDURE" {
                    callsOutright = true
                    return resolveChains()
                }
                if startsNextQuery(at: index, end: end) || (token.kind == .open && startsQuery(index..<end)) {
                    index = max(index + 1, queryExpression(index..<end, parent: nil, commonTables: [:]).end)
                    continue
                }
                index += 1
            }
            resolveChains()
        }

        // MARK: - Queries

        private mutating func queryExpression(
            _ range: Range<Int>,
            parent: Int?,
            commonTables: [String: CommonTable]
        ) -> (first: Int?, end: Int) {
            var index = range.lowerBound
            let end = range.upperBound
            var scope = commonTables
            if word(at: index) == "WITH" {
                guard let next = commonTableList(from: index + 1, end: end, scope: &scope) else {
                    callsOutright = true
                    return (nil, end)
                }
                index = next
            }
            var first: Int?
            var last: Int?
            var lastIsSelect = false
            var compound = false
            while index < end {
                if tokens[index].kind == .open, let close = closing[index], close < end {
                    let block = queryExpression((index + 1)..<close, parent: parent, commonTables: scope).first
                    first = first ?? block
                    last = block
                    lastIsSelect = false
                    index = close + 1
                } else if word(at: index) == "SELECT" {
                    let stop = branchEnd(from: index, end: end)
                    let block = selectBlock(index..<stop, parent: parent, commonTables: scope)
                    first = first ?? block
                    last = block
                    lastIsSelect = true
                    index = stop
                } else {
                    callsOutright = true
                    return (first, end)
                }
                guard index < end, let operatorWord = word(at: index), Self.setOperators.contains(operatorWord) else {
                    break
                }
                compound = true
                index += 1
                if word(at: index) == "ALL" || word(at: index) == "DISTINCT" { index += 1 }
            }
            if compound, lastIsSelect, let last, let first {
                blocks[last].orderByNamesOf = first
            }
            let stop = index < end ? statementEnd(from: index, end: end) : end
            if index < stop {
                // ORDER BY, OFFSET or FETCH after a parenthesized query: the whole query's, seeing its output names.
                let tail = newBlock(parent: nil)
                blocks[tail].orderByNamesOf = first ?? tail
                expression(index..<stop, block: tail, commonTables: scope, ordersBy: true)
            }
            return (first, stop)
        }

        // Where the next query starts at this depth: a SELECT, or a WITH that opens a named query.
        private func statementEnd(from start: Int, end: Int) -> Int {
            let depth = tokens[start].depth
            var index = start
            while index < end {
                if tokens[index].depth == depth, startsNextQuery(at: index, end: end) { return index }
                index += 1
            }
            return end
        }

        private func startsNextQuery(at index: Int, end: Int) -> Bool {
            switch word(at: index) {
            case "SELECT":
                return true
            case "WITH":
                guard identifier(at: index + 1) != nil, index + 2 < end else { return false }
                return word(at: index + 2) == "AS" || tokens[index + 2].kind == .open
            default:
                return false
            }
        }

        // `name [(columns)] AS (query) [SEARCH ... | CYCLE ...], ...`. Nil when it is not that shape, as with an inline
        // PL/SQL `WITH FUNCTION`.
        private mutating func commonTableList(
            from start: Int,
            end: Int,
            scope: inout [String: CommonTable]
        ) -> Int? {
            var index = start
            while index < end {
                guard let name = identifier(at: index) else { return nil }
                index += 1
                var columns: [String]?
                if index < end, tokens[index].kind == .open, let close = closing[index] {
                    columns = identifierList((index + 1)..<close)
                    index = close + 1
                }
                guard word(at: index) == "AS", index + 1 < end, tokens[index + 1].kind == .open,
                      let close = closing[index + 1], close < end
                else { return nil }
                scope[name] = CommonTable(block: nil, columns: columns)
                let body = queryExpression((index + 2)..<close, parent: nil, commonTables: scope).first
                scope[name] = CommonTable(block: body, columns: columns)
                index = close + 1
                let depth = tokens[start].depth
                while index < end, tokens[index].depth >= depth, tokens[index].kind != .comma,
                      tokens[index].kind != .open, word(at: index) != "SELECT" {
                    index += 1
                }
                guard index < end, tokens[index].kind == .comma else { return index }
                index += 1
            }
            return nil
        }

        private func branchEnd(from start: Int, end: Int) -> Int {
            let depth = tokens[start].depth
            var index = start + 1
            while index < end {
                if tokens[index].depth == depth {
                    if let word = tokens[index].word, Self.setOperators.contains(word) { return index }
                    if startsNextQuery(at: index, end: end) { return index }
                }
                index += 1
            }
            return end
        }

        private mutating func selectBlock(
            _ range: Range<Int>,
            parent: Int?,
            commonTables: [String: CommonTable]
        ) -> Int {
            let block = newBlock(parent: parent)
            let depth = tokens[range.lowerBound].depth
            var marks: [(index: Int, clause: Clause)] = []
            for index in (range.lowerBound + 1)..<range.upperBound where tokens[index].depth == depth {
                if let clause = clauseStart(at: index, end: range.upperBound, afterFrom: !marks.isEmpty) {
                    marks.append((index, clause))
                }
            }
            selectList((range.lowerBound + 1)..<(marks.first?.index ?? range.upperBound), block: block, commonTables)
            for (position, mark) in marks.enumerated() {
                let stop = position + 1 < marks.count ? marks[position + 1].index : range.upperBound
                let segment = (mark.index + 1)..<stop
                switch mark.clause {
                case .from:
                    fromClause(segment, block: block, commonTables: commonTables)
                case .orderBy:
                    expression(segment, block: block, commonTables: commonTables, ordersBy: true)
                case .other:
                    expression(segment, block: block, commonTables: commonTables, ordersBy: false)
                }
            }
            return block
        }

        private func clauseStart(at index: Int, end: Int, afterFrom: Bool) -> Clause? {
            guard let word = word(at: index) else { return nil }
            let next = index + 1 < end ? self.word(at: index + 1) : nil
            switch word {
            case "FROM":
                return afterFrom ? nil : .from
            case "WHERE", "HAVING", "INTO":
                return .other
            case "GROUP":
                return next == "BY" && self.word(at: index - 1) != "WITHIN" ? .other : nil
            case "ORDER":
                return next == "BY" || next == "SIBLINGS" ? .orderBy : nil
            case "CONNECT":
                return next == "BY" ? .other : nil
            case "START":
                return next == "WITH" ? .other : nil
            case "FOR":
                return next == "UPDATE" ? .other : nil
            case "MODEL", "WINDOW", "OFFSET":
                return afterFrom ? .other : nil
            case "FETCH":
                return afterFrom && (next == "FIRST" || next == "NEXT") ? .other : nil
            default:
                return nil
            }
        }

        // MARK: - Select list

        private mutating func selectList(_ range: Range<Int>, block: Int, _ commonTables: [String: CommonTable]) {
            var start = range.lowerBound
            while start < range.upperBound, let word = word(at: start), ["DISTINCT", "UNIQUE", "ALL"].contains(word) {
                start += 1
            }
            // Dameng's `TOP n [PERCENT] [WITH TIES]`, whose count would otherwise read as an operand an alias follows.
            if word(at: start) == "TOP", start + 1 < range.upperBound {
                start += 1
                if tokens[start].kind == .open, let close = closing[start] {
                    expression(start..<(close + 1), block: block, commonTables: commonTables, ordersBy: false)
                    start = close + 1
                } else {
                    start += 1
                }
                while start < range.upperBound, let word = word(at: start), ["PERCENT", "WITH", "TIES"].contains(word) {
                    start += 1
                }
            }
            guard start < range.upperBound else { return }
            let depth = tokens[start].depth
            var itemStart = start
            for index in start...range.upperBound {
                guard index == range.upperBound || (tokens[index].kind == .comma && tokens[index].depth == depth) else {
                    continue
                }
                if itemStart < index { selectItem(itemStart..<index, block: block, commonTables) }
                itemStart = index + 1
            }
        }

        private mutating func selectItem(_ item: Range<Int>, block: Int, _ commonTables: [String: CommonTable]) {
            let last = item.upperBound - 1
            if isSymbol(Self.star, at: last) {
                let qualifiers = chainNames(item.lowerBound..<last)
                if item.count == 1 {
                    blocks[block].outputs.append(.all)
                    return
                }
                if let qualifier = qualifiers?.last {
                    blocks[block].outputs.append(.allOf(qualifier))
                    return
                }
            }
            var expressionEnd = item.upperBound
            if item.count >= 2, let alias = identifier(at: last) {
                if word(at: last - 1) == "AS" {
                    expressionEnd = last - 1
                } else if endsOperand(at: last - 1) {
                    expressionEnd = last
                }
                if expressionEnd != item.upperBound {
                    blocks[block].aliases.insert(alias)
                    blocks[block].outputs.append(.name(alias))
                }
            }
            if expressionEnd == item.upperBound, let names = chainNames(item), let name = names.last {
                blocks[block].outputs.append(.name(name))
            }
            expression(item.lowerBound..<expressionEnd, block: block, commonTables: commonTables, ordersBy: false)
        }

        // `a`, `a.b` or `a.b.c` filling the whole range, or nil.
        private func chainNames(_ range: Range<Int>) -> [String]? {
            guard !range.isEmpty, range.count % 2 == 1 else { return nil }
            var names: [String] = []
            for index in range {
                if (index - range.lowerBound) % 2 == 0 {
                    guard let name = (index == range.lowerBound ? identifier(at: index) : chainPart(at: index)) else {
                        return nil
                    }
                    names.append(name)
                } else if !isSymbol(Self.period, at: index) {
                    return nil
                }
            }
            return names
        }

        // MARK: - FROM

        private mutating func fromClause(_ range: Range<Int>, block: Int, commonTables: [String: CommonTable]) {
            guard !range.isEmpty else { return }
            let depth = tokens[range.lowerBound].depth
            var state = FromState.expectTable
            var lateral = false
            var current: Int?
            var index = range.lowerBound
            let end = range.upperBound
            while index < end {
                let token = tokens[index]
                let word = token.word
                if token.kind == .comma, token.depth == depth {
                    state = .expectTable
                    current = nil
                    index += 1
                    continue
                }
                if let word, Self.joinWords.contains(word) {
                    state = .expectTable
                    current = nil
                    index += 1
                    continue
                }
                if let word, Self.joinPrefixes.contains(word) {
                    index += 1
                    continue
                }
                switch word {
                case "LATERAL":
                    lateral = true
                    index += 1
                    continue
                case "ON":
                    let stop = fromBoundary(after: index, end: end, depth: depth)
                    expression((index + 1)..<stop, block: block, commonTables: commonTables, ordersBy: false)
                    index = stop
                    state = .afterAlias
                    continue
                case "USING", "PARTITION", "SUBPARTITION", "SAMPLE", "SEED":
                    // Column, partition and sample names call nothing; the values of `PARTITION FOR (...)` are read.
                    index += 1
                    let readsValues = self.word(at: index) == "FOR"
                    if readsValues || self.word(at: index) == "BLOCK" { index += 1 }
                    if index < end, tokens[index].kind == .open, let close = closing[index] {
                        if readsValues {
                            expression((index + 1)..<close, block: block, commonTables: commonTables, ordersBy: false)
                        }
                        index = close + 1
                    }
                    continue
                case "VERSIONS":
                    let stop = fromBoundary(after: index, end: end, depth: depth)
                    expression((index + 1)..<stop, block: block, commonTables: commonTables, ordersBy: false)
                    index = stop
                    continue
                case "AS" where self.word(at: index + 1) == "OF":
                    let stop = fromBoundary(after: index, end: end, depth: depth)
                    expression((index + 2)..<stop, block: block, commonTables: commonTables, ordersBy: false)
                    index = stop
                    continue
                case "PIVOT", "UNPIVOT", "MATCH_RECOGNIZE":
                    // The body sees the table it reshapes and nothing beside it; what comes out has columns nobody read.
                    let body = newBlock(parent: nil)
                    if let current {
                        blocks[body].sources = [blocks[block].sources[current]]
                        blocks[block].sources[current] = .opaque(alias: nil)
                    }
                    index += 1
                    while let modifier = self.word(at: index), ["XML", "INCLUDE", "EXCLUDE", "NULLS"].contains(modifier) {
                        index += 1
                    }
                    if index < end, tokens[index].kind == .open, let close = closing[index] {
                        // A row pattern variable qualifies the reshaped table's columns: `up.price`.
                        if word == "MATCH_RECOGNIZE", let input = blocks[body].sources.first {
                            for variable in patternVariables((index + 1)..<close) {
                                blocks[body].sources.append(input.named(variable))
                            }
                        }
                        expression(
                            (index + 1)..<close, block: body, commonTables: commonTables, ordersBy: false,
                            readsAfterAs: word == "MATCH_RECOGNIZE"
                        )
                        index = close + 1
                    }
                    state = .afterTable
                    continue
                default:
                    break
                }
                // Parentheses no rule above took still hold expressions, and a query inside them is read.
                if state != .expectTable, token.kind == .open, let close = closing[index], close < end {
                    expression(index..<(close + 1), block: block, commonTables: commonTables, ordersBy: false)
                    index = close + 1
                    continue
                }
                switch state {
                case .expectTable:
                    guard let next = tableReference(
                        at: index, end: end, block: block, lateral: lateral, commonTables: commonTables
                    ) else {
                        index += 1
                        continue
                    }
                    index = next.end
                    current = next.source
                    lateral = false
                    state = .afterTable
                case .afterTable:
                    if word == "AS" {
                        index += 1
                        continue
                    }
                    guard let alias = identifier(at: index), !Self.fromKeywords.contains(alias) else {
                        index += 1
                        continue
                    }
                    index += 1
                    var columns: [String]?
                    if index < end, tokens[index].kind == .open, let close = closing[index] {
                        columns = identifierList((index + 1)..<close)
                        index = close + 1
                    }
                    if let current { naming(current, in: block, alias: alias, columns: columns) }
                    state = .afterAlias
                case .afterAlias:
                    index += 1
                }
            }
        }

        // One FROM item: a subquery, a parenthesized join, `TABLE(...)`, a table function, a remote table or a name.
        private mutating func tableReference(
            at index: Int,
            end: Int,
            block: Int,
            lateral: Bool,
            commonTables: [String: CommonTable]
        ) -> (end: Int, source: Int?)? {
            if tokens[index].kind == .open, let close = closing[index], close < end {
                // Oracle 23ai's `(VALUES (...), (...)) t (a, b)`, which sees no table beside it, as an inline view does.
                if let first = ((index + 1)..<close).first(where: { tokens[$0].kind != .open }), word(at: first) == "VALUES" {
                    let values = newBlock(parent: lateral ? block : nil)
                    expression((index + 1)..<close, block: values, commonTables: commonTables, ordersBy: false)
                    return (close + 1, append(.opaque(alias: nil), to: block))
                }
                if startsQuery((index + 1)..<close) {
                    let derived = queryExpression(
                        (index + 1)..<close, parent: lateral ? block : nil, commonTables: commonTables
                    ).first
                    return (close + 1, append(.derived(block: derived, columns: nil, alias: nil), to: block))
                }
                fromClause((index + 1)..<close, block: block, commonTables: commonTables)
                return (close + 1, nil)
            }
            if let word = word(at: index), word == "TABLE" || word == "THE",
               index + 1 < end, tokens[index + 1].kind == .open, let close = closing[index + 1] {
                expression((index + 2)..<close, block: block, commonTables: commonTables, ordersBy: false)
                return (close + 1, append(.opaque(alias: nil), to: block))
            }
            guard let first = identifier(at: index) else { return nil }
            var parts = [first]
            var last = index
            while isSymbol(Self.period, at: last + 1), let part = chainPart(at: last + 2) {
                parts.append(part)
                last += 2
            }
            if last + 1 < end, tokens[last + 1].kind == .open, let close = closing[last + 1] {
                expression((last + 2)..<close, block: block, commonTables: commonTables, ordersBy: false)
                return (close + 1, append(.opaque(alias: nil), to: block))
            }
            let name = parts[parts.count - 1]
            if isSymbol(Self.at, at: last + 1) {
                var stop = last + 2
                while stop < end, chainPart(at: stop) != nil || isSymbol(Self.period, at: stop) {
                    stop += 1
                }
                return (stop, append(.opaque(alias: name), to: block))
            }
            if parts.count == 1, let common = commonTables[name] {
                return (last + 1, append(.derived(block: common.block, columns: common.columns, alias: name), to: block))
            }
            let table = SQLTableName(owner: parts.count >= 2 ? parts[parts.count - 2] : nil, name: name)
            return (last + 1, append(.table(table, alias: nil), to: block))
        }

        // The names `PATTERN (...)` and `SUBSET x = (...)` give.
        private func patternVariables(_ range: Range<Int>) -> [String] {
            var names: [String] = []
            var index = range.lowerBound
            while index < range.upperBound {
                if word(at: index) == "PATTERN", index + 1 < range.upperBound, tokens[index + 1].kind == .open,
                   let close = closing[index + 1] {
                    names += ((index + 2)..<close).compactMap { identifier(at: $0) }
                    index = close + 1
                    continue
                }
                if word(at: index) == "SUBSET", let name = identifier(at: index + 1) {
                    names.append(name)
                }
                index += 1
            }
            return names
        }

        private mutating func naming(_ source: Int, in block: Int, alias: String, columns: [String]?) {
            switch blocks[block].sources[source] {
            case .table(let table, _):
                blocks[block].sources[source] = .table(table, alias: alias)
            case .derived(let derived, let declared, _):
                blocks[block].sources[source] = .derived(block: derived, columns: columns ?? declared, alias: alias)
            case .opaque:
                blocks[block].sources[source] = columns.map { .derived(block: nil, columns: $0, alias: alias) }
                    ?? .opaque(alias: alias)
            }
        }

        private mutating func append(_ source: Block.Source, to block: Int) -> Int {
            blocks[block].sources.append(source)
            return blocks[block].sources.count - 1
        }

        private func fromBoundary(after index: Int, end: Int, depth: Int) -> Int {
            var next = index + 1
            while next < end {
                let token = tokens[next]
                if token.depth == depth {
                    if token.kind == .comma { return next }
                    if let word = token.word, Self.joinWords.contains(word) || Self.joinPrefixes.contains(word) {
                        return next
                    }
                }
                next += 1
            }
            return end
        }

        // MARK: - Expressions

        // `readsAfterAs`: MATCH_RECOGNIZE's `DEFINE v AS <condition>`, where AS leads an expression, not a type.
        private mutating func expression(
            _ range: Range<Int>,
            block: Int,
            commonTables: [String: CommonTable],
            ordersBy: Bool,
            readsAfterAs: Bool = false
        ) {
            var index = range.lowerBound
            let end = range.upperBound
            var afterAs = false
            while index < end {
                let token = tokens[index]
                if token.kind == .open {
                    guard let close = closing[index], close < end else { return }
                    let inner = (index + 1)..<close
                    if startsQuery(inner) {
                        _ = queryExpression(inner, parent: block, commonTables: commonTables)
                    } else {
                        expression(inner, block: block, commonTables: commonTables, ordersBy: false, readsAfterAs: readsAfterAs)
                    }
                    index = close + 1
                    afterAs = false
                    continue
                }
                if token.word == "AS" {
                    afterAs = !readsAfterAs
                    index += 1
                    continue
                }
                guard let name = identifier(at: index) else {
                    afterAs = false
                    index += 1
                    continue
                }
                // A type or a name in CAST, XMLELEMENT or JSON_TABLE, or a bind variable.
                if afterAs || isSymbol(Self.colon, at: index - 1) {
                    afterAs = false
                    index += 1
                    continue
                }
                var parts = [name]
                var last = index
                while isSymbol(Self.period, at: last + 1) {
                    if isSymbol(Self.star, at: last + 2) {
                        last += 2
                        parts = []
                        break
                    }
                    guard let part = chainPart(at: last + 2) else { break }
                    parts.append(part)
                    last += 2
                }
                // A call: the parenthesis scan reads its name, and its arguments are read next.
                if last + 1 < end, tokens[last + 1].kind == .open {
                    index = last + 1
                    continue
                }
                if isSymbol(Self.at, at: last + 1) {
                    callsOutright = true
                    return
                }
                if parts.count == 1 {
                    blocks[block].candidates.append(.name(name, seesAliases: ordersBy))
                } else if parts.count > 1 {
                    blocks[block].chains.append(parts)
                }
                index = last + 1
            }
        }

        private mutating func resolveChains() {
            for index in blocks.indices {
                for parts in blocks[index].chains {
                    if visibleSource(answering: parts[0], from: index) {
                        blocks[index].candidates.append(.member(root: parts[0], member: parts[1]))
                    } else if parts.count >= 3, visibleTable(owner: parts[0], name: parts[1], from: index) {
                        continue
                    } else if parts.count <= 3, let last = parts.last, last == "NEXTVAL" || last == "CURRVAL" {
                        continue
                    } else {
                        callsOutright = true
                    }
                }
            }
        }

        private func visibleSource(answering qualifier: String, from index: Int) -> Bool {
            scope(from: index).contains { $0.answers(to: qualifier) }
        }

        private func visibleTable(owner: String, name: String, from index: Int) -> Bool {
            scope(from: index).contains { source in
                guard case .table(let table, nil) = source else { return false }
                return table.owner == owner && table.name == name
            }
        }

        private func scope(from index: Int) -> [Block.Source] {
            var sources: [Block.Source] = []
            var current: Int? = index
            var hops = 0
            while let block = current, hops <= blocks.count {
                sources += blocks[block].sources
                current = blocks[block].parent
                hops += 1
            }
            return sources
        }

        // MARK: - Tokens

        private mutating func newBlock(parent: Int?) -> Int {
            blocks.append(Block(parent: parent))
            return blocks.count - 1
        }

        private func startsQuery(_ range: Range<Int>) -> Bool {
            guard let first = range.first(where: { tokens[$0].kind != .open }) else { return false }
            return word(at: first) == "SELECT" || word(at: first) == "WITH"
        }

        private func identifierList(_ range: Range<Int>) -> [String] {
            guard !range.isEmpty else { return [] }
            let depth = tokens[range.lowerBound].depth
            return range.compactMap { tokens[$0].depth == depth ? identifier(at: $0) : nil }
        }

        private func word(at index: Int) -> String? {
            tokens.indices.contains(index) ? tokens[index].word : nil
        }

        private func isSymbol(_ symbol: UInt16, at index: Int) -> Bool {
            index >= 0 && code.isSymbol(symbol, at: index)
        }

        // A name as the catalog stores it: unquoted in capitals, quoted as written. Nil for a reserved word, a literal or
        // a symbol.
        private func identifier(at index: Int) -> String? {
            guard tokens.indices.contains(index) else { return nil }
            if case .word(let word) = tokens[index].kind {
                return reserved.contains(word) ? nil : word
            }
            return quotedOrWideName(at: index)
        }

        // After a period any word names a member, a reserved one too.
        private func chainPart(at index: Int) -> String? {
            guard tokens.indices.contains(index) else { return nil }
            if case .word(let word) = tokens[index].kind { return word }
            return quotedOrWideName(at: index)
        }

        private func quotedOrWideName(at index: Int) -> String? {
            let token = tokens[index]
            switch token.kind {
            case .name:
                var end = token.location
                while end < code.text.length, SQLFunctionCallScanner.isIdentifierUnit(code.text.character(at: end)) {
                    end += 1
                }
                return code.text.substring(with: NSRange(location: token.location, length: end - token.location))
                    .uppercased()
            case .quoted:
                guard let span = SQLNonCodeSpan.span(at: token.location, in: code.text, grammar: grammar),
                      code.text.character(at: span.start) == Self.doubleQuote
                else { return nil }
                let inner = NSRange(location: span.start + 1, length: max(0, span.contentEnd - span.start - 1))
                return code.text.substring(with: inner).replacingOccurrences(of: "\"\"", with: "\"", options: .literal)
            default:
                return nil
            }
        }

        // A name, a literal, a number or a closing parenthesis, which an alias may follow.
        private func endsOperand(at index: Int) -> Bool {
            guard tokens.indices.contains(index) else { return false }
            switch tokens[index].kind {
            case .quoted, .name, .close:
                return true
            case .word(let word):
                return word == "NULL"
                    || (!SQLBareNameCalls.oracleReservedWords.contains(word) && !Self.operatorWords.contains(word))
            case .other:
                let unit = code.text.character(at: tokens[index].location)
                return unit >= Self.digitZero && unit <= Self.digitZero + 9
            default:
                return false
            }
        }

        private static let setOperators: Set<String> = ["UNION", "INTERSECT", "MINUS", "EXCEPT"]
        private static let joinWords: Set<String> = ["JOIN", "APPLY"]
        private static let joinPrefixes: Set<String> = ["INNER", "LEFT", "RIGHT", "FULL", "OUTER", "CROSS", "NATURAL"]

        // Words a table can be followed by that are not its alias.
        private static let fromKeywords: Set<String> = joinWords.union(joinPrefixes).union([
            "USING", "PARTITION", "SUBPARTITION", "SAMPLE", "SEED", "PIVOT", "UNPIVOT", "MATCH_RECOGNIZE", "VERSIONS",
            "LATERAL", "MODEL", "WINDOW", "OFFSET", "FETCH", "LIMIT",
        ])

        // Words after which an operand follows, so a name after one is never an alias.
        private static let operatorWords: Set<String> = [
            "CASE", "WHEN", "THEN", "ELSE", "LIKEC", "LIKE2", "LIKE4", "ESCAPE", "MEMBER", "SUBMULTISET", "MULTISET",
            "EXCEPT", "SOME", "ANY", "ALL", "AT", "ZONE", "TIME", "LOCAL", "INTERVAL", "DATE", "TIMESTAMP", "NEW",
            "CURSOR", "CONNECT_BY_ROOT", "COLLATE", "TO", "DAY", "MONTH", "YEAR", "HOUR", "MINUTE", "SECOND", "OVER",
            "KEEP", "WITHIN", "TYPE", "JSON", "A", "EMPTY", "DANGLING", "PRESENT", "NAN", "INFINITE", "RETURNING",
            "FORMAT", "DISTINCT", "PRIOR", "NOT", "AND", "OR", "IS", "IN", "LIKE", "BETWEEN", "EXISTS", "AS", "DIV",
            "MOD", "XOR", "REGEXP", "RLIKE", "BINARY",
        ]

        private static let period = UInt16(UnicodeScalar(".").value)
        private static let star = UInt16(UnicodeScalar("*").value)
        private static let colon = UInt16(UnicodeScalar(":").value)
        private static let at = UInt16(UnicodeScalar("@").value)
        private static let doubleQuote = UInt16(UnicodeScalar("\"").value)
        private static let digitZero = UInt16(UnicodeScalar("0").value)
    }
}
