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
    public let record: CKRecord

    public init(_ record: CKRecord) {
        self.record = record
    }

    public subscript(field: Field) -> Any? {
        get { record[field.key] }
        nonmutating set {
            guard field.isWritable else { return }
            let replacement = newValue as? any CKRecordValueProtocol
            guard !CKRecord.isEqualRecordValue(record[field.key], replacement) else { return }
            record[field.key] = replacement
        }
    }
}

public extension CKRecord {
    func fields<Field: SyncSchemaField>(_ type: Field.Type) -> SyncRecordFields<Field> {
        SyncRecordFields(self)
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
