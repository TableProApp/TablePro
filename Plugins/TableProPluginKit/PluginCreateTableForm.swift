import Foundation

/// A Create Table form a driver describes and the app renders natively.
///
/// For an engine whose tables are not a list of typed columns: a DynamoDB table declares its key
/// attributes, its capacity and its secondary indexes, and none of that fits the column grid the
/// app offers SQL engines. The driver turns the submitted values into the statements the app
/// previews and runs, so the form never executes anything on its own.
public struct PluginCreateTableFormSpec: Sendable, Hashable {
    public let sections: [PluginFormSection]
    public let footnote: String?

    public init(sections: [PluginFormSection], footnote: String? = nil) {
        self.sections = sections
        self.footnote = footnote
    }
}

public struct PluginFormSection: Sendable, Hashable {
    public let id: String
    public let title: String?
    public let fields: [PluginFormField]
    /// A repeating section is a list of entries, each with its own copy of `fields`, which the
    /// user adds and removes. Its values arrive in `PluginCreateTableRequest.repeatedValues`.
    public let isRepeating: Bool
    public let addLabel: String?
    public let maximumCount: Int?

    public init(
        id: String,
        title: String?,
        fields: [PluginFormField],
        isRepeating: Bool = false,
        addLabel: String? = nil,
        maximumCount: Int? = nil
    ) {
        self.id = id
        self.title = title
        self.fields = fields
        self.isRepeating = isRepeating
        self.addLabel = addLabel
        self.maximumCount = maximumCount
    }
}

public struct PluginFormField: Sendable, Hashable {
    public enum Kind: Sendable, Hashable {
        case text(placeholder: String?, isRequired: Bool)
        case integer(defaultValue: Int?, minimum: Int?, maximum: Int?)
        case picker(options: [PluginFormOption], defaultValue: String)
        case toggle(defaultValue: Bool)
    }

    public let id: String
    public let label: String
    public let kind: Kind
    public let visibleWhen: PluginFormCondition?
    public let help: String?

    public init(
        id: String,
        label: String,
        kind: Kind,
        visibleWhen: PluginFormCondition? = nil,
        help: String? = nil
    ) {
        self.id = id
        self.label = label
        self.kind = kind
        self.visibleWhen = visibleWhen
        self.help = help
    }

    /// The value the field holds before the user touches it, spelled as it is submitted.
    public var initialValue: String {
        switch kind {
        case .text:
            return ""
        case .integer(let defaultValue, _, _):
            return defaultValue.map(String.init) ?? ""
        case .picker(_, let defaultValue):
            return defaultValue
        case .toggle(let defaultValue):
            return defaultValue ? "true" : "false"
        }
    }
}

public struct PluginFormOption: Sendable, Hashable {
    public let value: String
    public let label: String

    public init(value: String, label: String) {
        self.value = value
        self.label = label
    }
}

/// When a field is shown. `values` nil means "whenever the other field is not empty".
public struct PluginFormCondition: Sendable, Hashable {
    public let fieldId: String
    public let values: [String]?

    public init(fieldId: String, values: [String]?) {
        self.fieldId = fieldId
        self.values = values
    }

    public func isSatisfied(by entry: [String: String]) -> Bool {
        let current = entry[fieldId]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard let values else { return !current.isEmpty }
        return values.contains(current)
    }
}

public struct PluginCreateTableRequest: Sendable, Hashable {
    public let tableName: String
    public let values: [String: String]
    /// One array per repeating section, keyed by the section's id, one dictionary per entry.
    public let repeatedValues: [String: [[String: String]]]

    public init(tableName: String, values: [String: String], repeatedValues: [String: [[String: String]]] = [:]) {
        self.tableName = tableName
        self.values = values
        self.repeatedValues = repeatedValues
    }
}

/// Why a Create Table form cannot become statements yet, in words for the person filling it in.
public struct PluginCreateTableFormError: Error, LocalizedError, Sendable, Equatable {
    public let message: String
    public let fieldId: String?

    public init(message: String, fieldId: String? = nil) {
        self.message = message
        self.fieldId = fieldId
    }

    public var errorDescription: String? { message }
}
