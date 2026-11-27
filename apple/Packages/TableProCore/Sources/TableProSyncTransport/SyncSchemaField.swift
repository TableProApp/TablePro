import CloudKit
import Foundation

public enum ProductionSchemaState: Sendable {
    case verified
    case unverified
}

public protocol SyncSchemaField: CaseIterable, Hashable, Sendable {
    static var verifiedInProduction: Set<Self> { get }
    var key: String { get }
}

public extension SyncSchemaField {
    var productionSchemaState: ProductionSchemaState {
        Self.verifiedInProduction.contains(self) ? .verified : .unverified
    }

    var isWritable: Bool { productionSchemaState == .verified }

    static var writableKeys: Set<String> {
        Set(allCases.filter(\.isWritable).map(\.key))
    }

    static var declaredKeys: Set<String> {
        Set(allCases.map(\.key))
    }
}

public extension SyncSchemaField where Self: RawRepresentable, Self.RawValue == String {
    var key: String { rawValue }
}

public struct SyncRecordFields<Field: SyncSchemaField> {
    // What nil means for a key the record does not hold. A save sends only the keys the record names
    // (WWDC 2014, session 231), so an unnamed key keeps the server's value.
    public enum AbsentValueWrite: Sendable {
        // For a mapper merging into the server's copy, which leaves alone what it was not asked about.
        case leave
        // For a mapper building the whole record from the local model, where an empty field was emptied.
        case clear
    }

    public let record: CKRecord
    private let absentValues: AbsentValueWrite
    private let schema: SyncWritableSchema

    public init(_ record: CKRecord, absentValues: AbsentValueWrite = .leave, schema: SyncWritableSchema = .production) {
        self.record = record
        self.absentValues = absentValues
        self.schema = schema
    }

    public subscript(field: Field) -> Any? {
        get { record[field.key] }
        nonmutating set {
            guard schema.writes(field) else { return }
            let replacement = newValue as? any CKRecordValueProtocol
            guard !CKRecord.isEqualRecordValue(record[field.key], replacement)
                || (replacement == nil && absentValues == .clear) else { return }
            record[field.key] = replacement
        }
    }
}

public extension CKRecord {
    func fields<Field: SyncSchemaField>(
        _ type: Field.Type,
        absentValues: SyncRecordFields<Field>.AbsentValueWrite = .leave,
        schema: SyncWritableSchema = .production
    ) -> SyncRecordFields<Field> {
        SyncRecordFields(self, absentValues: absentValues, schema: schema)
    }

    static func isEqualRecordValue(_ lhs: Any?, _ rhs: Any?) -> Bool {
        switch (lhs, rhs) {
        case (nil, nil):
            return true
        case (let lhs as NSObject, let rhs as NSObject):
            return lhs.isEqual(rhs)
        default:
            return false
        }
    }
}
