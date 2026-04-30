import Foundation

internal struct CreateDatabaseFormSpec: Sendable {
    internal struct Option: Sendable, Hashable {
        internal let value: String
        internal let label: String
        internal let subtitle: String?
        internal let group: String?
    }

    internal enum FieldKind: Sendable {
        case picker(options: [Option], defaultValue: String?)
        case searchable(options: [Option], defaultValue: String?)
    }

    internal struct Visibility: Sendable {
        internal let fieldId: String
        internal let equals: String
    }

    internal struct Field: Sendable, Identifiable {
        internal let id: String
        internal let label: String
        internal let kind: FieldKind
        internal let visibleWhen: Visibility?
        internal let groupedBy: String?
    }

    internal let fields: [Field]
    internal let footnote: String?
}

internal struct CreateDatabaseRequest: Sendable {
    internal let name: String
    internal let values: [String: String]
}
