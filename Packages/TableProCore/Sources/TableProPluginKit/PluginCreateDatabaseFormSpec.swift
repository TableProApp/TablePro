import Foundation

public struct PluginCreateDatabaseFormSpec: Sendable {
    public struct Option: Sendable, Hashable {
        public let value: String
        public let label: String
        public let subtitle: String?
        public let group: String?

        public init(value: String, label: String, subtitle: String? = nil, group: String? = nil) {
            self.value = value
            self.label = label
            self.subtitle = subtitle
            self.group = group
        }
    }

    public enum FieldKind: Sendable {
        case picker(options: [Option], defaultValue: String?)
        case searchable(options: [Option], defaultValue: String?)
    }

    public struct Visibility: Sendable {
        public let fieldId: String
        public let equals: String

        public init(fieldId: String, equals: String) {
            self.fieldId = fieldId
            self.equals = equals
        }
    }

    public struct Field: Sendable {
        public let id: String
        public let label: String
        public let kind: FieldKind
        public let visibleWhen: Visibility?
        public let groupedBy: String?

        public init(
            id: String,
            label: String,
            kind: FieldKind,
            visibleWhen: Visibility? = nil,
            groupedBy: String? = nil
        ) {
            self.id = id
            self.label = label
            self.kind = kind
            self.visibleWhen = visibleWhen
            self.groupedBy = groupedBy
        }
    }

    public let fields: [Field]
    public let footnote: String?

    public init(fields: [Field], footnote: String? = nil) {
        self.fields = fields
        self.footnote = footnote
    }
}

public struct PluginCreateDatabaseRequest: Sendable {
    public let name: String
    public let values: [String: String]

    public init(name: String, values: [String: String]) {
        self.name = name
        self.values = values
    }
}
