import Foundation
import TableProNumberFormatting
import TableProPluginKit

// The numeric type each top-level number of a read document held, by the document's row locator. One field can hold
// int32, int64, double and decimal128 side by side, and the column's majority kind would retype a cell on save.
nonisolated struct MongoDBNumberKinds: Sendable {
    private var kindsByLocator: [String: [String: BsonValueKind]] = [:]
    private(set) var count = 0

    static let empty = MongoDBNumberKinds()

    static let cellLimit = 100_000

    private static let numberKinds: Set<BsonValueKind> = [.int32, .int64, .double, .decimal128]

    // A document holding no number is kept as an empty entry, so merging it clears what an earlier read recorded.
    static func recording(_ read: MongoReadDocuments, representation: MongoDBUuidRepresentation) -> MongoDBNumberKinds {
        var recorded = MongoDBNumberKinds()
        for (document, text) in zip(read.dictionaries, read.texts) {
            guard let locator = MongoDocumentIdentity.locator(inDocument: text) else { continue }
            var kinds: [String: BsonValueKind] = [:]
            for (field, value) in document where field != MongoDBCollectionDDL.idField {
                let kind = BsonDocumentFlattener.valueKind(for: value, representation: representation)
                if numberKinds.contains(kind) { kinds[field] = kind }
            }
            recorded.kindsByLocator[locator] = kinds
            recorded.count += kinds.count
        }
        return recorded
    }

    var isEmpty: Bool { kindsByLocator.isEmpty }

    func kinds(ofRow locator: String) -> [String: BsonValueKind]? {
        kindsByLocator[locator]
    }

    // A document read again replaces what was recorded for it, since its fields can have changed type or gone.
    func merging(_ page: MongoDBNumberKinds) -> MongoDBNumberKinds {
        var merged = self
        for (locator, kinds) in page.kindsByLocator {
            merged.count -= merged.kindsByLocator[locator]?.count ?? 0
            merged.kindsByLocator[locator] = kinds.isEmpty ? nil : kinds
            merged.count += kinds.count
        }
        return merged
    }
}

// What a driver's reads recorded, by the same collection key as its other caches. Past `cellLimit` a collection starts
// over from the latest read, and a row no longer recorded is typed by its column.
nonisolated final class MongoDBNumberKindStore: @unchecked Sendable {
    private let lock = NSLock()
    private var byCollection: [String: MongoDBNumberKinds] = [:]

    func remember(_ read: MongoReadDocuments, representation: MongoDBUuidRepresentation, collection key: String) {
        let page = MongoDBNumberKinds.recording(read, representation: representation)
        guard !page.isEmpty else { return }
        lock.withLock {
            let merged = (byCollection[key] ?? .empty).merging(page)
            byCollection[key] = merged.count > MongoDBNumberKinds.cellLimit ? MongoDBNumberKinds.empty.merging(page) : merged
        }
    }

    func kinds(ofRows rowLocators: [Int: String], collection key: String) -> [Int: [String: BsonValueKind]] {
        guard let kinds = lock.withLock({ byCollection[key] }) else { return [:] }
        return rowLocators.compactMapValues { kinds.kinds(ofRow: $0) }
    }

    func forget(collectionsWhere isStale: (String) -> Bool) {
        lock.withLock { byCollection = byCollection.filter { !isStale($0.key) } }
    }
}

nonisolated enum MongoDBDoubleText {
    // `0.1` and `4` are doubles exactly as typed; `9007199254740993` is not, a double rounds it to ...992.
    static func isExact(_ text: String) -> Bool {
        guard let parsed = Double(text), parsed.isFinite,
              let typed = DecimalDigits(text), let held = DecimalDigits(parsed.description) else { return false }
        return typed == held
    }

    // A JSON number as sign, significant digits and power of ten, so `4`, `4.0` and `0.4e1` compare equal.
    private struct DecimalDigits: Equatable {
        let isNegative: Bool
        let significand: String
        let exponent: Int

        init?(_ text: String) {
            guard NumberText.isJSONNumberLiteral(text) else { return nil }
            var rest = Substring(text)
            let isNegative = rest.first == "-"
            if isNegative { rest = rest.dropFirst() }
            var exponent = 0
            if let marker = rest.firstIndex(where: { $0 == "e" || $0 == "E" }) {
                guard let power = Int(rest[rest.index(after: marker)...]), power.magnitude < 1 << 32 else { return nil }
                exponent = power
                rest = rest[..<marker]
            }
            var digits = String(rest)
            if let point = rest.firstIndex(of: ".") {
                let fraction = rest[rest.index(after: point)...]
                digits = String(rest[..<point]) + String(fraction)
                exponent -= fraction.count
            }
            digits = String(digits.drop(while: { $0 == "0" }))
            guard !digits.isEmpty else {
                self.isNegative = false
                self.significand = ""
                self.exponent = 0
                return
            }
            while digits.last == "0" {
                digits.removeLast()
                exponent += 1
            }
            self.isNegative = isNegative
            self.significand = digits
            self.exponent = exponent
        }
    }
}
