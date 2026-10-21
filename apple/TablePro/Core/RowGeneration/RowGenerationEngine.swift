//
//  RowGenerationEngine.swift
//  TablePro
//

import Foundation
import TableProPluginKit

internal enum RowGenerationError: LocalizedError, Equatable {
    case uniqueValuesExhausted([String])
    case noMatchingReference([String])

    internal var errorDescription: String? {
        switch self {
        case .uniqueValuesExhausted(let columns):
            return String(
                format: String(localized: "Could not make another value for (%@) that does not repeat. Widen its range or generate fewer rows."),
                columns.joined(separator: ", ")
            )
        case .noMatchingReference(let columns):
            return String(
                format: String(localized: "No referenced row for (%@) agrees with the values its other foreign keys picked."),
                columns.joined(separator: ", ")
            )
        }
    }
}

internal enum RowGenerationBooleanStyle: Sendable {
    case words
    case digits

    internal func text(_ value: Bool) -> String {
        switch self {
        case .words: value ? "true" : "false"
        case .digits: value ? "1" : "0"
        }
    }
}

// Makes the rows one at a time, in order, from the settings and the seed alone: the same input gives the same rows.
// Holds what it has made so far for unique columns, so one engine serves one run; it is not shared between threads.
internal final class RowGenerationEngine: @unchecked Sendable {
    private static let randomAttempts = 32
    private static let groupAttempts = 64
    // Past this many values a key is not walked one by one: the preview runs on the main actor.
    private static let walkLimit: Int64 = 5_000_000
    // Version 7 timestamps count up from 2025-01-01 by the row, so the values sort in insert order.
    private static let uuidEpochMilliseconds: UInt64 = 1_735_689_600_000

    internal let columnNames: [String]

    private var columns: [ColumnState]
    private var sources: [String: SourceState]
    private let sourceOrder: [String]
    private let groups: [[Int]]
    private var groupSeen: [Set<Fingerprint>]
    private var groupGenerators: [SeededGenerator]
    private let booleanStyle: RowGenerationBooleanStyle
    private let nullsAreDistinct: Bool
    private var ordinal: Int64 = 0

    // `nullsAreDistinct` is false where a unique key counts two NULLs as equal, as SQL Server's does.
    internal init(
        table: RowGenerationTable,
        settings: RowGenerationSettings,
        booleanStyle: RowGenerationBooleanStyle,
        nullsAreDistinct: Bool = true,
        calendar: Calendar = .current
    ) {
        let written = table.columns.compactMap { column -> ColumnState? in
            guard let columnSettings = settings.columns[column.name], columnSettings.kind != .serverDefault else {
                return nil
            }
            return ColumnState(column: column, settings: columnSettings, seed: settings.seed, table: table, calendar: calendar)
        }
        columns = written
        columnNames = written.map(\.column.name)
        self.booleanStyle = booleanStyle
        self.nullsAreDistinct = nullsAreDistinct

        let positions = Dictionary(written.enumerated().map { ($1.column.name, $0) }, uniquingKeysWith: { first, _ in first })
        var sources: [String: SourceState] = [:]
        var order: [String] = []
        for (index, state) in written.enumerated() where state.settings.kind == .reference {
            guard let slot = state.column.reference, let source = table.reference(id: slot.sourceId) else { continue }
            if sources[slot.sourceId] == nil {
                order.append(slot.sourceId)
                sources[slot.sourceId] = SourceState(
                    source: source,
                    generator: SeededGenerator(seed: settings.seed, stream: "reference:\(slot.sourceId)")
                )
            }
            sources[slot.sourceId]?.members.append(index)
        }
        // A column two foreign keys share takes its value from the first; the second only picks among its own rows
        // that agree with it, so drawing waits until the first has drawn.
        for id in order {
            guard var state = sources[id] else { continue }
            for (position, name) in state.source.columns.enumerated() {
                guard let owner = positions[name], written[owner].settings.kind == .reference,
                      let ownerSource = written[owner].column.reference?.sourceId, ownerSource != id,
                      sources[ownerSource] != nil else { continue }
                state.bindings.append(SourceBinding(position: position, owner: owner))
            }
            if !state.bindings.isEmpty {
                let bindings = state.bindings
                state.candidates = Dictionary(grouping: state.source.tuples.indices) { tuple in
                    Fingerprint(bindings.map { state.source.tuples[tuple].indices.contains($0.position) ? state.source.tuples[tuple][$0.position] : .null })
                }
            }
            sources[id] = state
        }
        self.sources = sources
        sourceOrder = order.filter { sources[$0]?.bindings.isEmpty != false } + order.filter { sources[$0]?.bindings.isEmpty == false }

        let groups = table.uniqueGroups.compactMap { group -> [Int]? in
            var indices: [Int] = []
            for name in group {
                if let index = positions[name] {
                    // A member that never repeats already keeps the key unique.
                    if written[index].column.isUnique || written[index].settings.kind == .sequence { return nil }
                    indices.append(index)
                } else if table.column(named: name)?.ownership == .assigned {
                    // So does one the server numbers itself.
                    return nil
                }
                // Any other member left to the server takes its default, the same in every row, so the rest of
                // the key has to be unique on its own.
            }
            return indices.isEmpty ? nil : indices
        }
        self.groups = groups
        groupSeen = Array(repeating: [], count: groups.count)
        groupGenerators = groups.indices.map { SeededGenerator(seed: settings.seed, stream: "key:\($0)") }
    }

    internal func nextRows(_ count: Int) throws -> [[PluginCellValue]] {
        var rows: [[PluginCellValue]] = []
        rows.reserveCapacity(count)
        for _ in 0..<count {
            rows.append(try nextRow())
        }
        return rows
    }

    internal func nextRow() throws -> [PluginCellValue] {
        let drawn = try drawSources()
        var row = [PluginCellValue](repeating: .null, count: columns.count)
        for index in columns.indices {
            row[index] = try value(at: index, drawn: drawn)
        }
        if !groups.isEmpty {
            var settled = drawn
            try enforceGroups(row: &row, drawn: &settled)
        }
        ordinal += 1
        return row
    }

    // A foreign key that shares a column with another may find none of its rows agree with what the other drew,
    // so the whole draw is repeated.
    private func drawSources() throws -> [String: Int] {
        var unmatched: String?
        for _ in 0..<Self.randomAttempts {
            var drawn: [String: Int] = [:]
            unmatched = nil
            for id in sourceOrder {
                guard try drawSource(id, drawn: &drawn) else {
                    unmatched = id
                    break
                }
            }
            guard unmatched != nil else { return drawn }
            for id in sourceOrder {
                release(id, drawn: drawn)
            }
        }
        let names = unmatched.flatMap { sources[$0]?.source.columns } ?? []
        throw RowGenerationError.noMatchingReference(names)
    }

    // MARK: - Columns

    private func value(at index: Int, drawn: [String: Int]) throws -> PluginCellValue {
        let column = columns[index].column
        if !column.isUnique, column.isNullable, columns[index].generator.chance(columns[index].settings.nullRatio) {
            return .null
        }
        if columns[index].settings.kind == .reference {
            return referenceValue(at: index, drawn: drawn)
        }
        var value = draw(at: index)
        guard column.isUnique else { return value }
        var attempts = 1
        while !remember(value, at: index) {
            guard attempts < Self.randomAttempts else {
                return try fallback(at: index, after: value)
            }
            value = draw(at: index)
            attempts += 1
        }
        return value
    }

    private func isKey(_ value: PluginCellValue) -> Bool {
        !(value.isNull && nullsAreDistinct)
    }

    private func remember(_ value: PluginCellValue, at index: Int) -> Bool {
        guard isKey(value) else { return true }
        return columns[index].seen.insert(Fingerprint([value])).inserted
    }

    private func isTaken(_ value: PluginCellValue, at index: Int) -> Bool {
        isKey(value) && columns[index].seen.contains(Fingerprint([value]))
    }

    private func forget(_ value: PluginCellValue, at index: Int) {
        columns[index].seen.remove(Fingerprint([value]))
    }

    private func fallback(at index: Int, after value: PluginCellValue) throws -> PluginCellValue {
        let state = columns[index]
        let name = state.column.name
        if state.settings.kind.takesDisambiguatingSuffix, case .text(let base) = value {
            while columns[index].suffix < Int.max - 1 {
                columns[index].suffix += 1
                guard let candidate = disambiguate(base, suffix: columns[index].suffix, state: state) else { break }
                if remember(.text(candidate), at: index) { return .text(candidate) }
            }
            throw RowGenerationError.uniqueValuesExhausted([name])
        }
        guard let size = state.domainSize, size > 0, state.walksDomain else {
            throw RowGenerationError.uniqueValuesExhausted([name])
        }
        // A pattern is drawn character by character, so its walk starts anywhere rather than at the last draw.
        var position = state.settings.kind == .pattern
            ? columns[index].generator.integer(in: 0...(size - 1))
            : state.lastPosition
        for _ in 0..<min(size, Self.walkLimit) {
            position = position + 1 >= size ? 0 : position + 1
            let candidate = domainValue(of: state, at: position)
            guard !candidate.isNull else { continue }
            if remember(candidate, at: index) {
                columns[index].lastPosition = position
                return candidate
            }
        }
        throw RowGenerationError.uniqueValuesExhausted([name])
    }

    private func disambiguate(_ base: String, suffix: Int, state: ColumnState) -> String? {
        let limit = state.column.maxLength
        if state.settings.kind == .email, let at = base.lastIndex(of: "@") {
            let tail = ".\(suffix)" + base[at...]
            guard let local = Self.clipped(String(base[..<at]), toFit: tail.count, within: limit) else { return nil }
            return local + tail
        }
        let tail = " \(suffix)"
        guard let head = Self.clipped(base, toFit: tail.count, within: limit) else { return nil }
        return head + tail
    }

    private static func clipped(_ text: String, toFit tailLength: Int, within limit: Int?) -> String? {
        guard let limit else { return text }
        let room = limit - tailLength
        guard room >= 1 else { return nil }
        return String(text.prefix(room))
    }

    // MARK: - Foreign keys

    // One draw per foreign key and row, so every column of a key over several columns comes from one referenced
    // row. A key column that must not repeat claims its value here, before the row is built around it. False when
    // none of the key's rows agree with a column it shares with another key.
    private func drawSource(_ id: String, drawn: inout [String: Int]) throws -> Bool {
        guard let state = sources[id], !state.source.tuples.isEmpty else { return true }
        var pool: [Int]?
        if !state.bindings.isEmpty {
            let key = Fingerprint(state.bindings.map { boundValue(of: $0.owner, drawn: drawn) })
            pool = state.candidates[key] ?? []
            guard pool?.isEmpty == false else { return false }
        }
        let count = pool?.count ?? state.source.tuples.count
        func tuple(_ index: Int) -> Int { pool?[index] ?? index }
        let uniqueMembers = state.members.filter { columns[$0].column.isUnique }
        guard !uniqueMembers.isEmpty else {
            drawn[id] = tuple(sources[id]?.generator.index(below: count) ?? 0)
            return true
        }
        for _ in 0..<Self.randomAttempts {
            let pick = tuple(sources[id]?.generator.index(below: count) ?? 0)
            if claim(pick, of: state.source, for: uniqueMembers) {
                drawn[id] = pick
                return true
            }
        }
        let start = sources[id]?.generator.index(below: count) ?? 0
        for step in 1...count {
            let pick = tuple((start + step) % count)
            if claim(pick, of: state.source, for: uniqueMembers) {
                drawn[id] = pick
                return true
            }
        }
        throw RowGenerationError.uniqueValuesExhausted(uniqueMembers.map { columns[$0].column.name })
    }

    private func boundValue(of owner: Int, drawn: [String: Int]) -> PluginCellValue {
        guard let id = columns[owner].column.reference?.sourceId, let picked = drawn[id],
              let tuples = sources[id]?.source.tuples, tuples.indices.contains(picked) else { return .null }
        return tupleValue(tuples[picked], at: owner)
    }

    private func claim(_ pick: Int, of source: RowGenerationReferenceSource, for members: [Int]) -> Bool {
        let values = members.map { tupleValue(source.tuples[pick], at: $0) }
        guard !zip(members, values).contains(where: { isTaken($1, at: $0) }) else { return false }
        for (member, value) in zip(members, values) {
            _ = remember(value, at: member)
        }
        return true
    }

    private func release(_ id: String, drawn: [String: Int]) {
        guard let picked = drawn[id], let state = sources[id], state.source.tuples.indices.contains(picked) else { return }
        for member in state.members where columns[member].column.isUnique {
            forget(tupleValue(state.source.tuples[picked], at: member), at: member)
        }
    }

    private func tupleValue(_ tuple: [PluginCellValue], at index: Int) -> PluginCellValue {
        guard let position = columns[index].column.reference?.position, tuple.indices.contains(position) else { return .null }
        return tuple[position]
    }

    private func referenceValue(at index: Int, drawn: [String: Int]) -> PluginCellValue {
        guard let slot = columns[index].column.reference, let source = sources[slot.sourceId]?.source,
              let picked = drawn[slot.sourceId], source.tuples.indices.contains(picked) else { return .null }
        return tupleValue(source.tuples[picked], at: index)
    }

    // MARK: - Unique keys over several columns

    // Every key is checked against the finished row, so redrawing a column to settle one key cannot break another
    // key that shares it.
    private func enforceGroups(row: inout [PluginCellValue], drawn: inout [String: Int]) throws {
        var attempts = 0
        while let colliding = firstCollidingGroup(in: row) {
            attempts += 1
            if attempts < Self.groupAttempts {
                try redraw(group: colliding, row: &row, drawn: &drawn)
            } else if attempts < Self.groupAttempts + groups.count * 2 {
                try walk(group: colliding, row: &row, drawn: &drawn)
            } else {
                throw RowGenerationError.uniqueValuesExhausted(groups[colliding].map { columns[$0].column.name })
            }
        }
        for group in groups.indices {
            let members = groups[group].map { row[$0] }
            if members.allSatisfy(isKey) { groupSeen[group].insert(Fingerprint(members)) }
        }
    }

    private func firstCollidingGroup(in row: [PluginCellValue]) -> Int? {
        groups.indices.first { group in
            let members = groups[group].map { row[$0] }
            // NULL never equals NULL in a unique key on most engines, so such a row cannot collide there.
            guard members.allSatisfy(isKey) else { return false }
            return groupSeen[group].contains(Fingerprint(members))
        }
    }

    private func redraw(group: Int, row: inout [PluginCellValue], drawn: inout [String: Int]) throws {
        let members = groups[group]
        var touched: [String] = []
        for index in members {
            guard columns[index].settings.kind == .reference, let id = columns[index].column.reference?.sourceId,
                  !touched.contains(id) else { continue }
            touched.append(id)
            release(id, drawn: drawn)
            drawn[id] = nil
            guard try drawSource(id, drawn: &drawn) else {
                throw RowGenerationError.noMatchingReference(sources[id]?.source.columns ?? [])
            }
        }
        for index in columns.indices {
            let isMember = members.contains(index)
            let followsSource = columns[index].settings.kind == .reference
                && columns[index].column.reference.map { touched.contains($0.sourceId) } == true
            guard isMember || followsSource else { continue }
            if columns[index].column.isUnique, columns[index].settings.kind != .reference {
                forget(row[index], at: index)
            }
            row[index] = try value(at: index, drawn: drawn)
        }
    }

    private enum WalkDimension {
        case column(Int)
        case source(String)
    }

    // Near the end of a small key space random draws stop finding the last free combinations, so the remaining
    // ones are walked in order from a random start. A foreign key is one dimension, its referenced rows.
    private func walk(group: Int, row: inout [PluginCellValue], drawn: inout [String: Int]) throws {
        let members = linkedMembers(of: group)
        let names = members.map { columns[$0].column.name }
        var dimensions: [WalkDimension] = []
        var sizes: [Int64] = []
        for index in members {
            if columns[index].settings.kind == .reference {
                guard let id = columns[index].column.reference?.sourceId else { throw RowGenerationError.uniqueValuesExhausted(names) }
                if dimensions.contains(where: { if case .source(id) = $0 { return true } else { return false } }) { continue }
                guard let size = walkSize(ofSource: id) else { throw RowGenerationError.uniqueValuesExhausted(names) }
                dimensions.append(.source(id))
                sizes.append(size)
            } else {
                guard columns[index].walksDomain, let size = columns[index].domainSize, size > 0 else {
                    throw RowGenerationError.uniqueValuesExhausted(names)
                }
                dimensions.append(.column(index))
                sizes.append(size)
            }
        }
        var total: Int64 = 1
        for size in sizes {
            let product = total.multipliedReportingOverflow(by: size)
            guard !product.overflow, product.partialValue <= Self.walkLimit else {
                throw RowGenerationError.uniqueValuesExhausted(names)
            }
            total = product.partialValue
        }
        let start = groupGenerators[group].integer(in: 0...(total - 1))
        var candidate = row
        var picks: [String: Int] = [:]
        for step in 0..<total {
            var position = (start + step) % total
            for offset in dimensions.indices.reversed() {
                let local = position % sizes[offset]
                position /= sizes[offset]
                switch dimensions[offset] {
                case .column(let index):
                    candidate[index] = domainValue(of: columns[index], at: local)
                case .source(let id):
                    guard let state = sources[id] else { continue }
                    picks[id] = Int(local)
                    for member in state.members {
                        candidate[member] = tupleValue(state.source.tuples[Int(local)], at: member)
                    }
                }
            }
            guard firstCollidingGroup(in: candidate) == nil else { continue }
            row = candidate
            drawn.merge(picks) { _, new in new }
            return
        }
        throw RowGenerationError.uniqueValuesExhausted(names)
    }

    // Keys that share a column are walked together: settling one alone can leave no free value for the other.
    private func linkedMembers(of group: Int) -> [Int] {
        var members = Set(groups[group])
        var changed = true
        while changed {
            changed = false
            for other in groups where !members.isDisjoint(with: other) && !members.isSuperset(of: other) {
                members.formUnion(other)
                changed = true
            }
        }
        return members.sorted()
    }

    // A foreign key is walked over its referenced rows when nothing else depends on which one it picks: no column of
    // it must be unique on its own, and no other foreign key shares one of its columns.
    private func walkSize(ofSource id: String) -> Int64? {
        guard let state = sources[id], state.bindings.isEmpty,
              !state.members.contains(where: { columns[$0].column.isUnique }),
              !sources.values.contains(where: { other in other.bindings.contains { state.members.contains($0.owner) } })
        else { return nil }
        return Int64(state.source.tuples.count)
    }

    // MARK: - Values

    private func draw(at index: Int) -> PluginCellValue {
        let settings = columns[index].settings
        let text: String
        switch settings.kind {
        case .serverDefault, .reference:
            return .null
        case .sequence:
            text = String(settings.integerMinimum &+ settings.sequenceStep &* ordinal)
        case .integerRange where columns[index].domainSize == nil && settings.integerMinimum <= settings.integerMaximum:
            text = String(columns[index].generator.integer(in: settings.integerMinimum...settings.integerMaximum))
        case .decimalRange where columns[index].domainSize == nil && columns[index].decimalLowSteps <= columns[index].decimalHighSteps:
            let steps = columns[index].generator.integer(in: columns[index].decimalLowSteps...columns[index].decimalHighSteps)
            text = RowGenerationValueText.decimal(steps: steps, scale: settings.decimalScale)
        case .integerRange, .decimalRange, .list, .date, .dateTime, .time:
            guard let size = columns[index].domainSize, size > 0 else { return .null }
            let position = columns[index].generator.integer(in: 0...(size - 1))
            columns[index].lastPosition = position
            return domainValue(of: columns[index], at: position)
        case .boolean:
            let isTrue: Bool
            if columns[index].column.isUnique {
                isTrue = columns[index].generator.index(below: 2) == 1
                columns[index].lastPosition = isTrue ? 1 : 0
            } else {
                isTrue = columns[index].generator.chance(settings.trueRatio)
            }
            text = booleanStyle.text(isTrue)
        case .text:
            text = loremText(at: index, settings: settings)
        case .firstName:
            text = pick(RowValueVocabulary.firstNames, at: index)
        case .lastName:
            text = pick(RowValueVocabulary.lastNames, at: index)
        case .fullName:
            text = "\(pick(RowValueVocabulary.firstNames, at: index)) \(pick(RowValueVocabulary.lastNames, at: index))"
        case .email:
            text = email(at: index)
        case .phone:
            let area = columns[index].generator.integer(in: 200...999)
            let exchange = columns[index].generator.integer(in: 200...999)
            let line = columns[index].generator.integer(in: 0...9_999)
            text = "+1-\(area)-\(exchange)-\(String(format: "%04lld", line))"
        case .streetAddress:
            let number = columns[index].generator.integer(in: 1...9_999)
            text = "\(number) \(pick(RowValueVocabulary.streetNames, at: index)) \(pick(RowValueVocabulary.streetSuffixes, at: index))"
        case .city:
            text = pick(RowValueVocabulary.cities, at: index)
        case .country:
            text = pick(RowValueVocabulary.countries, at: index)
        case .uuid:
            text = uuid(at: index, version: settings.uuidVersion)
        case .pattern:
            text = RowGenerationPattern.expand(settings.pattern, using: &columns[index].generator)
        case .json:
            let identifier = columns[index].generator.integer(in: 1...100_000)
            let label = "\(pick(RowValueVocabulary.words, at: index)) \(pick(RowValueVocabulary.words, at: index))"
            let active = columns[index].generator.chance(0.5)
            text = "{\"id\":\(identifier),\"label\":\"\(label)\",\"active\":\(active)}"
        }
        return .text(Self.fitted(text, maxLength: columns[index].column.maxLength))
    }

    private func domainValue(of state: ColumnState, at position: Int64) -> PluginCellValue {
        let text: String
        switch state.settings.kind {
        case .integerRange:
            text = String(state.settings.integerMinimum &+ position)
        case .decimalRange:
            text = RowGenerationValueText.decimal(steps: state.decimalLowSteps &+ position, scale: state.settings.decimalScale)
        case .list:
            guard state.listValues.indices.contains(Int(position)) else { return .null }
            text = state.listValues[Int(position)]
        case .boolean:
            text = booleanStyle.text(position == 1)
        case .date:
            text = RowGenerationValueText.date(dayNumber: state.startDay + position)
        case .dateTime:
            text = RowGenerationValueText.dateTime(second: state.startDay * RowGenerationValueText.secondsPerDay + position)
        case .time:
            text = RowGenerationValueText.time(secondOfDay: position)
        case .pattern:
            text = RowGenerationPattern.value(at: position, in: state.settings.pattern, length: state.column.maxLength)
        default:
            return .null
        }
        return .text(Self.fitted(text, maxLength: state.column.maxLength))
    }

    private func pick(_ values: [String], at index: Int) -> String {
        values[columns[index].generator.index(below: values.count)]
    }

    private func loremText(at index: Int, settings: RowGeneratorSettings) -> String {
        let low = max(0, settings.minLength)
        let target = Int(columns[index].generator.integer(in: Int64(low)...Int64(max(low, settings.maxLength))))
        guard target > 0 else { return "" }
        var text = ""
        while text.count < target {
            let word = pick(RowValueVocabulary.words, at: index)
            text += text.isEmpty ? word.prefix(1).uppercased() + word.dropFirst() : " " + word
        }
        var clipped = String(text.prefix(target))
        while clipped.count > 1, clipped.hasSuffix(" ") { clipped.removeLast() }
        return clipped
    }

    private func email(at index: Int) -> String {
        let first = pick(RowValueVocabulary.firstNames, at: index).lowercased()
        let last = pick(RowValueVocabulary.lastNames, at: index).lowercased()
        let number = columns[index].generator.chance(0.5) ? String(columns[index].generator.integer(in: 1...999)) : ""
        let domain = pick(RowValueVocabulary.emailDomains, at: index)
        return "\(first).\(last)\(number)@\(domain)"
    }

    private func uuid(at index: Int, version: UUIDVersion) -> String {
        var bytes = (0..<16).map { _ in UInt8(truncatingIfNeeded: columns[index].generator.next()) }
        switch version {
        case .v4:
            bytes[6] = 0x40 | (bytes[6] & 0x0F)
        case .v7:
            let milliseconds = Self.uuidEpochMilliseconds &+ UInt64(bitPattern: ordinal)
            for position in 0..<6 {
                bytes[position] = UInt8(truncatingIfNeeded: milliseconds >> (8 * (5 - position)))
            }
            bytes[6] = 0x70 | (bytes[6] & 0x0F)
        }
        bytes[8] = 0x80 | (bytes[8] & 0x3F)
        let value = UUID(uuid: (
            bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6], bytes[7],
            bytes[8], bytes[9], bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15]
        ))
        return value.uuidString.lowercased()
    }

    private static func fitted(_ text: String, maxLength: Int?) -> String {
        guard let maxLength, text.count > maxLength else { return text }
        return String(text.prefix(max(0, maxLength)))
    }
}

// MARK: - State

private struct ColumnState {
    let column: RowGenerationColumn
    let settings: RowGeneratorSettings
    var generator: SeededGenerator
    var seen: Set<Fingerprint> = []
    var suffix = 0
    var lastPosition: Int64 = 0
    let domainSize: Int64?
    let listValues: [String]
    let startDay: Int64
    let decimalLowSteps: Int64
    let decimalHighSteps: Int64

    init(column: RowGenerationColumn, settings: RowGeneratorSettings, seed: UInt64, table: RowGenerationTable, calendar: Calendar) {
        self.column = column
        self.settings = settings
        generator = SeededGenerator(seed: seed, stream: "column:\(column.name)")
        var unique: [String] = []
        var seenValues: Set<String> = []
        for value in settings.values where !value.isEmpty && seenValues.insert(value).inserted {
            unique.append(value)
        }
        listValues = unique
        startDay = RowGenerationValueText.dayNumber(of: settings.dateStart, calendar: calendar)
        decimalLowSteps = RowGenerationValueText.steps(of: settings.decimalMinimum, scale: settings.decimalScale)
        decimalHighSteps = RowGenerationValueText.steps(of: settings.decimalMaximum, scale: settings.decimalScale)
        switch settings.kind {
        case .list:
            domainSize = Int64(unique.count)
        case .reference:
            domainSize = nil
        default:
            domainSize = RowGenerationValidation.domainSize(of: settings, for: column, in: table, calendar: calendar)
        }
    }

    // Whether every value the generator can make has a position, so a unique column can be walked value by value.
    var walksDomain: Bool {
        switch settings.kind {
        case .integerRange, .decimalRange, .list, .boolean, .date, .dateTime, .time, .pattern:
            return true
        default:
            return false
        }
    }
}

private struct SourceBinding {
    let position: Int
    let owner: Int
}

private struct SourceState {
    let source: RowGenerationReferenceSource
    var generator: SeededGenerator
    var members: [Int] = []
    var bindings: [SourceBinding] = []
    var candidates: [Fingerprint: [Int]] = [:]
}

// Two independent 64-bit hashes of a value's bytes. Remembering a million values as text would hold every string.
private struct Fingerprint: Hashable {
    let first: UInt64
    let second: UInt64

    init(_ values: [PluginCellValue]) {
        var first: UInt64 = 0xCBF2_9CE4_8422_2325
        var second: UInt64 = 0x6A09_E667_F3BC_C909
        func feed(_ byte: UInt8) {
            first = (first ^ UInt64(byte)) &* 0x0000_0100_0000_01B3
            second = (second ^ UInt64(byte)) &* 0x9E37_79B9_7F4A_7C15
            second = (second << 29) | (second >> 35)
        }
        for value in values {
            switch value {
            case .null:
                feed(0)
            case .text(let text):
                feed(1)
                text.utf8.forEach(feed)
            case .bytes(let data):
                feed(2)
                data.forEach(feed)
            }
            feed(0xFF)
        }
        self.first = first
        self.second = second
    }
}
