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

internal enum JSONSpliceOutcome {
    case unchanged(end: Int)
    case rewritten([UInt8], end: Int)
}

internal struct JSONObjectSplicer {
    private struct MemberPlan {
        var removed = false
        var newKey: String?
        var newLiteral: String?
    }

    private struct RowChanges {
        var byColumn: [Int: JSONMemberChange] = [:]
        var bySourceKey: [String: JSONMemberChange] = [:]
        var keyOrder: [String] = []
    }

    let cursor: JSONCursor
    let keyTable: JSONKeyTable
    let columnChanges: [JSONMemberChange?]
    let rules: JSONLiteralRules

    func splice(
        objectAt start: Int,
        edit: JSONObjectEdit?,
        predictor: inout JSONKeyPredictor
    ) throws -> JSONSpliceOutcome {
        var tokens: [JSONMemberToken] = []
        var columns: [Int?] = []
        var keyScratch: [UInt8] = []
        let end = try cursor.forEachMember(objectAt: start) { token in
            columns.append(column(of: token, ordinal: tokens.count, predictor: &predictor, scratch: &keyScratch))
            tokens.append(token)
        }
        let rowChanges = collectRowChanges(edit)
        var plans = [MemberPlan](repeating: MemberPlan(), count: tokens.count)
        var lastOccurrence: [Int: Int] = [:]
        for (position, column) in columns.enumerated() {
            guard let column else { continue }
            lastOccurrence[column] = position
        }
        var changed = false
        for (position, column) in columns.enumerated() {
            guard let column, let change = effectiveChange(for: column, rowChanges: rowChanges) else { continue }
            changed = true
            guard change != .remove else {
                plans[position].removed = true
                continue
            }
            plans[position].newKey = change.newKey
            if lastOccurrence[column] == position {
                plans[position].newLiteral = change.newLiteral
            }
        }
        var appended = absentMembers(present: lastOccurrence, rowChanges: rowChanges) + (edit?.appended ?? [])
        if !appended.isEmpty {
            appended = try mergeAppended(appended, tokens: tokens, plans: &plans)
            changed = true
        }
        guard changed else { return .unchanged(end: end) }
        for plan in plans {
            guard !plan.removed, let literal = plan.newLiteral else { continue }
            try rules.check(literal)
        }
        for member in appended {
            try rules.check(member.literal)
        }
        return .rewritten(render(objectRange: start..<end, tokens: tokens, plans: plans, appended: appended), end: end)
    }

    static func serialize(_ members: [JSONNewMember], rules: JSONLiteralRules) throws -> [UInt8] {
        var seen = Set<String>()
        for member in members {
            guard seen.insert(member.key).inserted else { throw JSONTableWriteError.duplicateKey(member.key) }
            try rules.check(member.literal)
        }
        return compactObject(members, nameSeparator: [JSONByte.colon], memberSeparator: [JSONByte.comma])
    }

    private func column(
        of token: JSONMemberToken,
        ordinal: Int,
        predictor: inout JSONKeyPredictor,
        scratch: inout [UInt8]
    ) -> Int? {
        guard token.keyHasEscapes else {
            return predictor.column(for: cursor.keyBytes(of: token), ordinal: ordinal, in: keyTable)
        }
        scratch.removeAll(keepingCapacity: true)
        JSONText.appendDecoded(cursor.keyBytes(of: token), into: &scratch)
        return scratch.withUnsafeBufferPointer { keyTable.column(for: $0) }
    }

    private func collectRowChanges(_ edit: JSONObjectEdit?) -> RowChanges {
        var changes = RowChanges()
        for memberEdit in edit?.edits ?? [] {
            let key = memberEdit.sourceKey
            if changes.bySourceKey[key] == nil {
                changes.keyOrder.append(key)
            }
            changes.bySourceKey[key] = changes.bySourceKey[key].map { $0.overridden(by: memberEdit.change) } ?? memberEdit.change
            guard let column = keyTable.column(named: key) else { continue }
            changes.byColumn[column] = changes.bySourceKey[key]
        }
        return changes
    }

    private func effectiveChange(for column: Int, rowChanges: RowChanges) -> JSONMemberChange? {
        let documentChange = column < columnChanges.count ? columnChanges[column] : nil
        guard let documentChange else { return rowChanges.byColumn[column] }
        return documentChange.overridden(by: rowChanges.byColumn[column])
    }

    private func absentMembers(present: [Int: Int], rowChanges: RowChanges) -> [JSONNewMember] {
        var members: [JSONNewMember] = []
        for key in rowChanges.keyOrder {
            let column = keyTable.column(named: key)
            if let column, present[column] != nil { continue }
            let change = column.flatMap { effectiveChange(for: $0, rowChanges: rowChanges) } ?? rowChanges.bySourceKey[key]
            guard let literal = change?.newLiteral else { continue }
            members.append(JSONNewMember(key: change?.newKey ?? key, literal: literal))
        }
        return members
    }

    private func mergeAppended(
        _ appended: [JSONNewMember],
        tokens: [JSONMemberToken],
        plans: inout [MemberPlan]
    ) throws -> [JSONNewMember] {
        var finalNames: [String: Int] = [:]
        for (position, token) in tokens.enumerated() where !plans[position].removed {
            finalNames[plans[position].newKey ?? cursor.key(of: token)] = position
        }
        var seen = Set<String>()
        var remaining: [JSONNewMember] = []
        for member in appended {
            guard seen.insert(member.key).inserted else { throw JSONTableWriteError.duplicateKey(member.key) }
            if let target = finalNames[member.key] {
                plans[target].newLiteral = member.literal
                continue
            }
            remaining.append(member)
        }
        return remaining
    }

    private func render(
        objectRange: Range<Int>,
        tokens: [JSONMemberToken],
        plans: [MemberPlan],
        appended: [JSONNewMember]
    ) -> [UInt8] {
        guard let first = tokens.first, let last = tokens.last else {
            return Self.compactObject(appended, nameSeparator: [JSONByte.colon], memberSeparator: [JSONByte.comma])
        }
        let kept = tokens.indices.filter { !plans[$0].removed }
        guard !kept.isEmpty || !appended.isEmpty else { return [JSONByte.openBrace, JSONByte.closeBrace] }
        var output: [UInt8] = []
        output.reserveCapacity(objectRange.count + 64)
        output.append(JSONByte.openBrace)
        let leading = (objectRange.lowerBound + 1)..<first.keyRange.lowerBound
        output.append(contentsOf: cursor.bytes(leading))
        for (position, index) in kept.enumerated() {
            if position > 0 {
                output.append(contentsOf: cursor.bytes(tokens[index - 1].valueRange.upperBound..<tokens[index].keyRange.lowerBound))
            }
            appendMember(tokens[index], plan: plans[index], into: &output)
        }
        let memberSeparator = memberSeparator(tokens: tokens, leading: leading)
        let nameSeparator = Array(cursor.bytes(last.keyRange.upperBound..<last.valueRange.lowerBound))
        for (position, member) in appended.enumerated() {
            if position > 0 || !kept.isEmpty {
                output.append(contentsOf: memberSeparator)
            }
            JSONText.appendStringLiteral(member.key, into: &output)
            output.append(contentsOf: nameSeparator)
            output.append(contentsOf: member.literal.utf8)
        }
        output.append(contentsOf: cursor.bytes(last.valueRange.upperBound..<(objectRange.upperBound - 1)))
        output.append(JSONByte.closeBrace)
        return output
    }

    private func appendMember(_ token: JSONMemberToken, plan: MemberPlan, into output: inout [UInt8]) {
        if let newKey = plan.newKey {
            JSONText.appendStringLiteral(newKey, into: &output)
        } else {
            output.append(contentsOf: cursor.bytes(token.keyRange))
        }
        output.append(contentsOf: cursor.bytes(token.keyRange.upperBound..<token.valueRange.lowerBound))
        if let literal = plan.newLiteral {
            output.append(contentsOf: literal.utf8)
        } else {
            output.append(contentsOf: cursor.bytes(token.valueRange))
        }
    }

    private func memberSeparator(tokens: [JSONMemberToken], leading: Range<Int>) -> [UInt8] {
        if tokens.count >= 2 {
            let previous = tokens[tokens.count - 2]
            let last = tokens[tokens.count - 1]
            return Array(cursor.bytes(previous.valueRange.upperBound..<last.keyRange.lowerBound))
        }
        return [JSONByte.comma] + Array(cursor.bytes(leading))
    }

    private static func compactObject(
        _ members: [JSONNewMember],
        nameSeparator: [UInt8],
        memberSeparator: [UInt8]
    ) -> [UInt8] {
        var output: [UInt8] = [JSONByte.openBrace]
        for (position, member) in members.enumerated() {
            if position > 0 {
                output.append(contentsOf: memberSeparator)
            }
            JSONText.appendStringLiteral(member.key, into: &output)
            output.append(contentsOf: nameSeparator)
            output.append(contentsOf: member.literal.utf8)
        }
        output.append(JSONByte.closeBrace)
        return output
    }
}
