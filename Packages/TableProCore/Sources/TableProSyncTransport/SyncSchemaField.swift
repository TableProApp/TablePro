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
    /// What writing nil means for a key the record does not already hold.
    ///
    /// `CKModifyRecordsOperation.savePolicy` is `.changedKeys`, so the server keeps whatever it has
    /// for any key the pushed record never names, and a key is named only once something assigns to
    /// it. The two answers are therefore genuinely different pushes, and which one is right depends
    /// on what the record being built is.
    public enum AbsentValueWrite: Sendable {
        /// Say nothing about the key, so the server keeps its value. Correct for a mapper that
        /// merges into the record the server last gave us, whose job is to leave alone what it was
        /// not asked about.
        case leave
        /// Name the key with no value, so the server clears it. Correct for a mapper that builds
        /// the whole record from the local model, where a field with no value is a value: it is the
        /// user having emptied it.
        case clear
    }

    public let record: CKRecord
    private let absentValues: AbsentValueWrite

    public init(_ record: CKRecord, absentValues: AbsentValueWrite = .leave) {
        self.record = record
        self.absentValues = absentValues
    }

    public subscript(field: Field) -> Any? {
        get { record[field.key] }
        nonmutating set {
            guard field.isWritable else { return }
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
        absentValues: SyncRecordFields<Field>.AbsentValueWrite = .leave
    ) -> SyncRecordFields<Field> {
        SyncRecordFields(self, absentValues: absentValues)
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
