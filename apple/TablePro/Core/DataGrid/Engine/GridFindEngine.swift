import Foundation
import TableProPluginKit

struct GridFindMatcher {
    struct InvalidPattern: Error {}

    private enum Strategy {
        case literal(needle: String, options: String.CompareOptions)
        case expression(NSRegularExpression)
    }

    private let strategy: Strategy
    private let expandsTemplates: Bool

    // Nil when the term finds nothing. A literal term is trimmed; a regular expression is taken as typed.
    static func make(term: String, options: GridFindState.Options) throws -> GridFindMatcher? {
        if options.usesRegularExpression {
            guard !term.isEmpty else { return nil }
            return try compiled(pattern: term, options: options, expandsTemplates: true)
        }
        let needle = term.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !needle.isEmpty else { return nil }
        if options.matchesWholeWord {
            return try compiled(
                pattern: NSRegularExpression.escapedPattern(for: needle),
                options: options,
                expandsTemplates: false
            )
        }
        let compare: String.CompareOptions = options.matchesCase ? [] : [.caseInsensitive, .diacriticInsensitive]
        return GridFindMatcher(strategy: .literal(needle: needle, options: compare), expandsTemplates: false)
    }

    private static func compiled(
        pattern: String,
        options: GridFindState.Options,
        expandsTemplates: Bool
    ) throws -> GridFindMatcher {
        let wrapped = options.matchesWholeWord ? "\\b(?:\(pattern))\\b" : pattern
        let expression: NSRegularExpression
        do {
            expression = try NSRegularExpression(pattern: wrapped, options: options.matchesCase ? [] : [.caseInsensitive])
        } catch {
            throw InvalidPattern()
        }
        return GridFindMatcher(strategy: .expression(expression), expandsTemplates: expandsTemplates)
    }

    func matches(_ text: String) -> Bool {
        switch strategy {
        case .literal(let needle, let options):
            return text.range(of: needle, options: options) != nil
        case .expression(let expression):
            return !Self.nonEmptyMatches(of: expression, in: text, limit: 1).isEmpty
        }
    }

    func replacing(in text: String, with template: String) -> (text: String, replacements: Int) {
        switch strategy {
        case .literal(let needle, let options):
            return Self.replacingLiteral(needle, options: options, in: text, with: template)
        case .expression(let expression):
            let found = Self.nonEmptyMatches(of: expression, in: text, limit: nil)
            guard !found.isEmpty else { return (text, 0) }
            let effectiveTemplate = expandsTemplates ? template : NSRegularExpression.escapedTemplate(for: template)
            let result = NSMutableString(string: text)
            var offset = 0
            for match in found {
                // Capture groups are read from the original text, where the match's ranges still point.
                let replacement = expression.replacementString(for: match, in: text, offset: 0, template: effectiveTemplate)
                result.replaceCharacters(
                    in: NSRange(location: match.range.location + offset, length: match.range.length),
                    with: replacement
                )
                offset += (replacement as NSString).length - match.range.length
            }
            return (result as String, found.count)
        }
    }

    private static func replacingLiteral(
        _ needle: String,
        options: String.CompareOptions,
        in text: String,
        with template: String
    ) -> (text: String, replacements: Int) {
        var result = ""
        var count = 0
        var cursor = text.startIndex
        while cursor < text.endIndex,
              let range = text.range(of: needle, options: options, range: cursor..<text.endIndex),
              !range.isEmpty {
            result.append(contentsOf: text[cursor..<range.lowerBound])
            result.append(template)
            count += 1
            cursor = range.upperBound
        }
        guard count > 0 else { return (text, 0) }
        result.append(contentsOf: text[cursor...])
        return (result, count)
    }

    // A pattern like `x*` matches the empty string in every cell, which highlights nothing.
    private static func nonEmptyMatches(
        of expression: NSRegularExpression,
        in text: String,
        limit: Int?
    ) -> [NSTextCheckingResult] {
        var found: [NSTextCheckingResult] = []
        expression.enumerateMatches(in: text, range: NSRange(text.startIndex..., in: text)) { match, _, stop in
            guard let match, match.range.length > 0 else { return }
            found.append(match)
            if let limit, found.count >= limit {
                stop.pointee = true
            }
        }
        return found
    }
}

@MainActor
enum GridFindEngine {
    struct Source {
        let rows: TableRows
        let order: DataGridRowOrder
        let columns: DataGridColumnSet
        var displayFormats: [ValueDisplayFormat?] = []
        var databaseType: DatabaseType?
        var revealsInvisibleCharacters = false
    }

    struct Result: Equatable {
        var matches: [GridFindState.Match] = []
        var problem: String?
    }

    struct Replacement: Equatable {
        var edits: [DataGridCellEdit] = []
        var replacements = 0

        var cells: Int { edits.count }
    }

    static var invalidPatternProblem: String {
        String(localized: "Invalid regular expression")
    }

    static func problem(term: String, options: GridFindState.Options) -> String? {
        do {
            _ = try GridFindMatcher.make(term: term, options: options)
            return nil
        } catch {
            return invalidPatternProblem
        }
    }

    static func search(_ term: String, options: GridFindState.Options, in source: Source) -> Result {
        let matcher: GridFindMatcher?
        do {
            matcher = try GridFindMatcher.make(term: term, options: options)
        } catch {
            return Result(problem: invalidPatternProblem)
        }
        guard let matcher else { return Result() }
        let searched = searchedColumns(options: options, in: source)
        guard !searched.isEmpty else { return Result() }

        var found: [GridFindState.Match] = []
        let rowCount = source.order.count(in: source.rows)
        for displayRow in 0..<rowCount {
            guard let row = source.order.row(at: displayRow, in: source.rows) else { continue }
            for column in searched {
                guard let text = searchableText(in: row, column: column, source: source),
                      matcher.matches(text) else { continue }
                found.append(GridFindState.Match(rowID: row.id, columnID: column.id))
            }
        }
        return Result(matches: found)
    }

    // A scope naming a column that is no longer presented searches every presented column.
    static func searchedColumns(options: GridFindState.Options, in source: Source) -> [DataGridColumn] {
        let candidates: [DataGridColumn]
        if let scope = options.columnScope, let scoped = source.columns.column(id: scope) {
            candidates = [scoped]
        } else {
            candidates = source.columns.columns
        }
        return candidates.filter { column in
            FindMatcher.isSearchable(column.type, displayFormat: displayFormat(for: column, in: source))
        }
    }

    // Nil for NULL, an empty cell, and bytes the column's format could not decode, which show as hex.
    static func searchableText(in row: Row, column: DataGridColumn, source: Source) -> String? {
        let dataIndex = column.dataIndex
        guard dataIndex < row.values.count else { return nil }
        let rawValue = row.values[dataIndex]
        let format = displayFormat(for: column, in: source)
        switch rawValue {
        case .null:
            return nil
        case .text:
            break
        case .bytes(let data):
            guard let format,
                  format.isApplicable(to: column.type, databaseType: source.databaseType),
                  ValueDisplayFormatter.apply(data, format: format, columnType: column.type) != nil else { return nil }
        }
        let shown = GridDisplayOrderResolver.displayValue(
            rawValue,
            columnType: column.type,
            displayFormat: format,
            databaseType: source.databaseType
        )
        guard !shown.isEmpty else { return nil }
        return source.revealsInvisibleCharacters ? shown : shown.shownWithoutMarks
    }

    // Replaces in the stored text, not the shown one: a cell shows a capped, single-line copy of its value.
    static func replacements(
        for matches: [GridFindState.Match],
        term: String,
        options: GridFindState.Options,
        template: String,
        in source: Source,
        isWritable: (DataGridColumn) -> Bool
    ) -> Replacement {
        guard let matcher = try? GridFindMatcher.make(term: term, options: options) else { return Replacement() }
        var result = Replacement()
        for match in matches {
            guard let column = source.columns.column(id: match.columnID),
                  isWritable(column),
                  let row = source.rows.row(withID: match.rowID),
                  column.dataIndex < row.values.count,
                  case .text(let original) = row.values[column.dataIndex] else { continue }
            let replaced = matcher.replacing(in: original, with: template)
            guard replaced.replacements > 0, replaced.text != original else { continue }
            result.edits.append(DataGridCellEdit(
                rowID: match.rowID,
                columnID: match.columnID,
                value: .enteredText(replaced.text)
            ))
            result.replacements += replaced.replacements
        }
        return result
    }

    static func position(of match: GridFindState.Match, in source: Source) -> GridCoord? {
        guard let row = source.order.displayIndex(of: match.rowID, in: source.rows),
              let column = source.columns.displayPosition(of: match.columnID) else { return nil }
        return GridCoord(row: row, displayColumn: column)
    }

    static func positions(of matches: [GridFindState.Match], in source: Source) -> [GridCoord?] {
        matches.map { position(of: $0, in: source) }
    }

    // MARK: - Stepping

    static func index(atOrAfter cell: GridCoord?, in positions: [GridCoord?]) -> Int? {
        guard !positions.isEmpty else { return nil }
        guard let cell else { return 0 }
        return positions.firstIndex { candidate in
            candidate.map { !precedes($0, cell) } ?? false
        } ?? 0
    }

    static func index(after cell: GridCoord, in positions: [GridCoord?]) -> Int? {
        guard !positions.isEmpty else { return nil }
        return positions.firstIndex { candidate in
            candidate.map { precedes(cell, $0) } ?? false
        } ?? 0
    }

    static func index(before cell: GridCoord, in positions: [GridCoord?]) -> Int? {
        guard !positions.isEmpty else { return nil }
        return positions.lastIndex { candidate in
            candidate.map { precedes($0, cell) } ?? false
        } ?? positions.count - 1
    }

    // Steps from the current match, or from the cursor once the user has moved it off that match.
    static func step(
        from current: Int?,
        active: GridCoord?,
        positions: [GridCoord?],
        forward: Bool
    ) -> Int? {
        guard !positions.isEmpty else { return nil }
        let currentPosition = current.flatMap { positions.indices.contains($0) ? positions[$0] : nil }
        if let active, currentPosition != active {
            return forward ? index(after: active, in: positions) : index(before: active, in: positions)
        }
        guard let current, positions.indices.contains(current) else {
            return forward ? 0 : positions.count - 1
        }
        let count = positions.count
        return forward ? (current + 1) % count : (current - 1 + count) % count
    }

    // MARK: - Stepping through an owner's dataset

    // A dataset's matches arrive in display order; bisection keeps a step to a few position lookups.
    static func sortedIndex(atOrAfter cell: GridCoord, count: Int, position: (Int) -> GridCoord?) -> Int? {
        guard count > 0 else { return nil }
        let index = partition(count: count) { candidate in position(candidate).map { precedes($0, cell) } ?? true }
        return index < count ? index : 0
    }

    static func sortedIndex(after cell: GridCoord, count: Int, position: (Int) -> GridCoord?) -> Int? {
        guard count > 0 else { return nil }
        let index = partition(count: count) { candidate in position(candidate).map { !precedes(cell, $0) } ?? true }
        return index < count ? index : 0
    }

    static func sortedIndex(before cell: GridCoord, count: Int, position: (Int) -> GridCoord?) -> Int? {
        guard count > 0 else { return nil }
        let index = partition(count: count) { candidate in position(candidate).map { precedes($0, cell) } ?? true }
        return index > 0 ? index - 1 : count - 1
    }

    private static func partition(count: Int, isBelow: (Int) -> Bool) -> Int {
        var low = 0
        var high = count
        while low < high {
            let middle = low + (high - low) / 2
            if isBelow(middle) {
                low = middle + 1
            } else {
                high = middle
            }
        }
        return low
    }

    nonisolated static func replacementMessage(replacements: Int, cells: Int) -> String {
        guard cells > 0 else { return String(localized: "No matches to replace.") }
        let matchPhrase = replacements == 1
            ? String(localized: "1 match")
            : String(format: String(localized: "%@ matches"), replacements.formatted())
        let cellPhrase = cells == 1
            ? String(localized: "1 cell")
            : String(format: String(localized: "%@ cells"), cells.formatted())
        return String(format: String(localized: "Replaced %1$@ in %2$@."), matchPhrase, cellPhrase)
    }

    private static func displayFormat(for column: DataGridColumn, in source: Source) -> ValueDisplayFormat? {
        column.dataIndex < source.displayFormats.count ? source.displayFormats[column.dataIndex] : nil
    }

    private static func precedes(_ lhs: GridCoord, _ rhs: GridCoord) -> Bool {
        lhs.row < rhs.row || (lhs.row == rhs.row && lhs.displayColumn < rhs.displayColumn)
    }
}
