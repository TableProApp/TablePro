import Foundation

internal struct JSONLiteralRules {
    let forbidsLineBreaks: Bool

    func check(_ literal: String) throws {
        var copy = literal
        let isValid = copy.withUTF8 { bytes -> Bool in
            (try? JSONRowParser.validateValue(in: bytes)) != nil
        }
        guard isValid else { throw JSONTableWriteError.invalidLiteral(literal) }
        guard forbidsLineBreaks else { return }
        if literal.utf8.contains(where: JSONByte.isLineBreak) {
            throw JSONTableWriteError.literalSpansLines(literal)
        }
    }
}

internal struct JSONColumnPlan {
    let removed: Bool
    let name: String?
    let key: [UInt8]?
    let literal: [UInt8]?

    init(_ change: JSONMemberChange) {
        removed = change == .remove
        name = change.newKey
        key = change.newKey.map(JSONObjectSplicer.encodedKey)
        literal = change.newLiteral.map { Array($0.utf8) }
    }
}

internal struct JSONSourceRun {
    private let cursor: JSONCursor
    private var start: Int
    private var end: Int

    init(cursor: JSONCursor, start: Int) {
        self.cursor = cursor
        self.start = start
        end = start
    }

    @inline(__always)
    mutating func copy(_ range: Range<Int>, into output: inout [UInt8]) {
        guard !range.isEmpty else { return }
        guard range.lowerBound != end else {
            end = range.upperBound
            return
        }
        flush(into: &output)
        start = range.lowerBound
        end = range.upperBound
    }

    @inline(__always)
    mutating func insert(_ bytes: [UInt8], into output: inout [UInt8]) {
        flush(into: &output)
        output.append(contentsOf: bytes)
    }

    @inline(__always)
    mutating func flush(into output: inout [UInt8]) {
        guard end > start else { return }
        output.append(contentsOf: cursor.bytes(start..<end))
        start = end
    }
}

internal struct JSONObjectSplicer {
    private struct MemberPlan {
        var removed = false
        var name: String?
        var key: [UInt8]?
        var literal: [UInt8]?
    }

    private struct RowChanges {
        var byColumn: [Int: JSONMemberChange] = [:]
        var bySourceKey: [String: JSONMemberChange] = [:]
        var keyOrder: [String] = []
    }

    let hasColumnPlans: Bool
    private let keyTable: JSONKeyTable
    private let columnPlans: [JSONColumnPlan?]
    private let rules: JSONLiteralRules
    private var predictor = JSONKeyPredictor()
    private var tokens: [JSONMemberToken] = []
    private var columns: [Int] = []
    private var plans: [MemberPlan] = []
    private var lastPositions: [Int]
    private var keyScratch: [UInt8] = []

    init(keyTable: JSONKeyTable, columnPlans: [JSONColumnPlan?], rules: JSONLiteralRules) {
        self.keyTable = keyTable
        self.columnPlans = columnPlans
        self.rules = rules
        hasColumnPlans = columnPlans.contains { $0 != nil }
        lastPositions = [Int](repeating: -1, count: keyTable.count)
    }

    static func encodedKey(_ name: String) -> [UInt8] {
        var bytes: [UInt8] = []
        JSONText.appendStringLiteral(name, into: &bytes)
        return bytes
    }

    static func appendNewObject(_ members: [JSONNewMember], rules: JSONLiteralRules, into output: inout [UInt8]) throws {
        var seen = Set<String>()
        for member in members {
            guard seen.insert(member.key).inserted else { throw JSONTableWriteError.duplicateKey(member.key) }
            try rules.check(member.literal)
        }
        appendCompactObject(members, into: &output)
    }

    mutating func splice(
        _ cursor: JSONCursor,
        objectAt start: Int,
        edit: JSONObjectEdit?,
        into output: inout [UInt8]
    ) throws -> Int {
        let end = try readMembers(cursor, objectAt: start)
        defer { clearLastPositions() }
        let rowChanges = try collectRowChanges(edit)
        var changed = planMembers(rowChanges)
        var appended: [JSONNewMember] = []
        if let edit {
            let requested = absentMembers(rowChanges) + edit.appended
            if !requested.isEmpty {
                appended = try mergeAppended(requested, cursor: cursor)
                changed = true
            }
        }
        guard changed else {
            output.append(contentsOf: cursor.bytes(start..<end))
            return end
        }
        render(cursor, objectRange: start..<end, appended: appended, into: &output)
        return end
    }

    private mutating func readMembers(_ cursor: JSONCursor, objectAt start: Int) throws -> Int {
        tokens.removeAll(keepingCapacity: true)
        columns.removeAll(keepingCapacity: true)
        let end = try cursor.forEachMember(objectAt: start) { token in
            columns.append(column(of: token, ordinal: tokens.count, cursor: cursor) ?? -1)
            tokens.append(token)
        }
        for (position, column) in columns.enumerated() where column >= 0 {
            lastPositions[column] = position
        }
        return end
    }

    private mutating func clearLastPositions() {
        for column in columns where column >= 0 {
            lastPositions[column] = -1
        }
    }

    private mutating func column(of token: JSONMemberToken, ordinal: Int, cursor: JSONCursor) -> Int? {
        guard token.keyHasEscapes else {
            return predictor.column(for: cursor.keyBytes(of: token), ordinal: ordinal, in: keyTable)
        }
        keyScratch.removeAll(keepingCapacity: true)
        JSONText.appendDecoded(cursor.keyBytes(of: token), into: &keyScratch)
        return keyScratch.withUnsafeBufferPointer { keyTable.column(for: $0) }
    }

    private func collectRowChanges(_ edit: JSONObjectEdit?) throws -> RowChanges {
        var changes = RowChanges()
        guard let edit else { return changes }
        for memberEdit in edit.edits {
            if let literal = memberEdit.change.newLiteral {
                try rules.check(literal)
            }
            let key = memberEdit.sourceKey
            if changes.bySourceKey[key] == nil {
                changes.keyOrder.append(key)
            }
            let merged = changes.bySourceKey[key].map { $0.overridden(by: memberEdit.change) } ?? memberEdit.change
            changes.bySourceKey[key] = merged
            if let column = keyTable.column(named: key) {
                changes.byColumn[column] = merged
            }
        }
        for member in edit.appended {
            try rules.check(member.literal)
        }
        return changes
    }

    private mutating func planMembers(_ rowChanges: RowChanges) -> Bool {
        plans.removeAll(keepingCapacity: true)
        var changed = false
        for (position, column) in columns.enumerated() {
            let isLast = column >= 0 && lastPositions[column] == position
            guard column >= 0, let plan = plan(forColumn: column, isLast: isLast, rowChanges: rowChanges) else {
                plans.append(MemberPlan())
                continue
            }
            changed = true
            plans.append(plan)
        }
        return changed
    }

    private func plan(forColumn column: Int, isLast: Bool, rowChanges: RowChanges) -> MemberPlan? {
        let documentPlan = column < columnPlans.count ? columnPlans[column] : nil
        let rowChange = rowChanges.byColumn.isEmpty ? nil : rowChanges.byColumn[column]
        guard documentPlan != nil || rowChange != nil else { return nil }
        if documentPlan?.removed == true || rowChange == .remove {
            return MemberPlan(removed: true)
        }
        let rowName = rowChange?.newKey
        let rowLiteral = rowChange?.newLiteral.map { Array($0.utf8) }
        return MemberPlan(
            name: rowName ?? documentPlan?.name,
            key: rowName.map(Self.encodedKey) ?? documentPlan?.key,
            literal: isLast ? rowLiteral ?? documentPlan?.literal : nil
        )
    }

    private func absentMembers(_ rowChanges: RowChanges) -> [JSONNewMember] {
        var members: [JSONNewMember] = []
        for key in rowChanges.keyOrder {
            let column = keyTable.column(named: key)
            if let column, lastPositions[column] >= 0 { continue }
            let documentPlan = column.flatMap { $0 < columnPlans.count ? columnPlans[$0] : nil }
            guard documentPlan?.removed != true,
                  let change = rowChanges.bySourceKey[key],
                  let literal = change.newLiteral
            else { continue }
            members.append(JSONNewMember(key: change.newKey ?? documentPlan?.name ?? key, literal: literal))
        }
        return members
    }

    private mutating func mergeAppended(_ appended: [JSONNewMember], cursor: JSONCursor) throws -> [JSONNewMember] {
        var finalNames: [String: Int] = [:]
        for (position, token) in tokens.enumerated() where !plans[position].removed {
            finalNames[plans[position].name ?? cursor.key(of: token)] = position
        }
        var seen = Set<String>()
        var remaining: [JSONNewMember] = []
        for member in appended {
            guard seen.insert(member.key).inserted else { throw JSONTableWriteError.duplicateKey(member.key) }
            guard let target = finalNames[member.key] else {
                remaining.append(member)
                continue
            }
            plans[target].literal = Array(member.literal.utf8)
        }
        return remaining
    }

    private func render(
        _ cursor: JSONCursor,
        objectRange: Range<Int>,
        appended: [JSONNewMember],
        into output: inout [UInt8]
    ) {
        guard let first = tokens.first, let last = tokens.last else {
            Self.appendCompactObject(appended, into: &output)
            return
        }
        guard plans.contains(where: { !$0.removed }) || !appended.isEmpty else {
            output.append(contentsOf: [JSONByte.openBrace, JSONByte.closeBrace])
            return
        }
        var run = JSONSourceRun(cursor: cursor, start: objectRange.lowerBound)
        run.copy(objectRange.lowerBound..<first.keyRange.lowerBound, into: &output)
        var emitted = 0
        for position in tokens.indices where !plans[position].removed {
            let token = tokens[position]
            if emitted > 0 {
                run.copy(tokens[position - 1].valueRange.upperBound..<token.keyRange.lowerBound, into: &output)
            }
            if let key = plans[position].key {
                run.insert(key, into: &output)
            } else {
                run.copy(token.keyRange, into: &output)
            }
            run.copy(token.keyRange.upperBound..<token.valueRange.lowerBound, into: &output)
            if let literal = plans[position].literal {
                run.insert(literal, into: &output)
            } else {
                run.copy(token.valueRange, into: &output)
            }
            emitted += 1
        }
        if !appended.isEmpty {
            run.flush(into: &output)
        }
        let leading = (objectRange.lowerBound + 1)..<first.keyRange.lowerBound
        for member in appended {
            if emitted > 0 {
                appendMemberSeparator(cursor, leading: leading, into: &output)
            }
            JSONText.appendStringLiteral(member.key, into: &output)
            output.append(contentsOf: cursor.bytes(last.keyRange.upperBound..<last.valueRange.lowerBound))
            output.append(contentsOf: member.literal.utf8)
            emitted += 1
        }
        run.copy(last.valueRange.upperBound..<objectRange.upperBound, into: &output)
        run.flush(into: &output)
    }

    private func appendMemberSeparator(_ cursor: JSONCursor, leading: Range<Int>, into output: inout [UInt8]) {
        guard tokens.count >= 2 else {
            output.append(JSONByte.comma)
            output.append(contentsOf: cursor.bytes(leading))
            return
        }
        let previous = tokens[tokens.count - 2]
        let last = tokens[tokens.count - 1]
        output.append(contentsOf: cursor.bytes(previous.valueRange.upperBound..<last.keyRange.lowerBound))
    }

    private static func appendCompactObject(_ members: [JSONNewMember], into output: inout [UInt8]) {
        output.append(JSONByte.openBrace)
        for (position, member) in members.enumerated() {
            if position > 0 {
                output.append(JSONByte.comma)
            }
            JSONText.appendStringLiteral(member.key, into: &output)
            output.append(JSONByte.colon)
            output.append(contentsOf: member.literal.utf8)
        }
        output.append(JSONByte.closeBrace)
    }
}
