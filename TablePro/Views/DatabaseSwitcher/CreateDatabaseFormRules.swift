//
//  CreateDatabaseFormRules.swift
//  TablePro
//
//  What a driver's create-database form does with its own answers.
//
//  A field can be hidden by another field's value, and a field's options can be
//  grouped by another field's value, so changing one answer can invalidate
//  another. Those rules used to live inside the sheet, which meant a second
//  caller either duplicated them or lost them. They are pure, so they are also
//  the part worth asserting.
//

import Foundation

internal enum CreateDatabaseFormRules {
    /// The driver's preferred answer where it has one, the first option where it does not.
    internal static func initialValues(for spec: CreateDatabaseFormSpec) -> [String: String] {
        var initial: [String: String] = [:]
        for field in spec.fields {
            let optionValues = options(from: field.kind).map(\.value)
            if let preferred = defaultValue(from: field.kind), optionValues.contains(preferred) {
                initial[field.id] = preferred
            } else if let first = optionValues.first {
                initial[field.id] = first
            }
        }
        return initial
    }

    /// The fields whose value decides another field's options, so a change to one has to reset the
    /// fields grouped under it.
    internal static func groupSourceFieldIds(in spec: CreateDatabaseFormSpec) -> Set<String> {
        Set(spec.fields.compactMap(\.groupedBy))
    }

    internal static func visibleFields(
        in spec: CreateDatabaseFormSpec,
        values: [String: String]
    ) -> [CreateDatabaseFormSpec.Field] {
        spec.fields.filter { isVisible($0, values: values) }
    }

    internal static func isVisible(_ field: CreateDatabaseFormSpec.Field, values: [String: String]) -> Bool {
        guard let visibility = field.visibleWhen else { return true }
        return values[visibility.fieldId] == visibility.equals
    }

    internal static func filteredOptions(
        for field: CreateDatabaseFormSpec.Field,
        values: [String: String]
    ) -> [CreateDatabaseFormSpec.Option] {
        let allOptions = options(from: field.kind)
        guard allOptions.contains(where: { $0.group != nil }) else { return allOptions }
        guard let sourceId = field.groupedBy, let groupValue = values[sourceId] else { return allOptions }
        return allOptions.filter { $0.group == groupValue }
    }

    /// A collation that belongs to the charset the user just moved away from is no longer offered,
    /// so leaving it selected would submit a pair the server refuses.
    internal static func resettingGroupedFields(
        after sourceId: String,
        in spec: CreateDatabaseFormSpec,
        values: [String: String]
    ) -> [String: String] {
        var updated = values
        for field in spec.fields where field.groupedBy == sourceId {
            let visible = filteredOptions(for: field, values: updated).map(\.value)
            if let preferred = defaultValue(from: field.kind), visible.contains(preferred) {
                updated[field.id] = preferred
            } else {
                updated[field.id] = visible.first ?? ""
            }
        }
        return updated
    }

    /// A hidden field's answer is stale rather than chosen, so it never reaches the server.
    internal static func submissionValues(
        from values: [String: String],
        spec: CreateDatabaseFormSpec
    ) -> [String: String] {
        values.filter { shouldSubmit($0.key, in: spec, values: values) }
    }

    internal static func missingRequiredInput(
        in spec: CreateDatabaseFormSpec,
        values: [String: String]
    ) -> Bool {
        spec.textInputs.contains { input in
            guard input.isRequired else { return false }
            return (values[input.id] ?? "").trimmingCharacters(in: .whitespaces).isEmpty
        }
    }

    internal static func displayLabel(for option: CreateDatabaseFormSpec.Option) -> String {
        guard let subtitle = option.subtitle, !subtitle.isEmpty else { return option.label }
        return "\(option.label) \(subtitle)"
    }

    private static func shouldSubmit(
        _ fieldId: String,
        in spec: CreateDatabaseFormSpec,
        values: [String: String]
    ) -> Bool {
        if spec.textInputs.contains(where: { $0.id == fieldId }) { return true }
        guard let field = spec.fields.first(where: { $0.id == fieldId }) else { return false }
        return isVisible(field, values: values)
    }

    private static func options(from kind: CreateDatabaseFormSpec.FieldKind) -> [CreateDatabaseFormSpec.Option] {
        switch kind {
        case .picker(let options, _), .searchable(let options, _):
            return options
        }
    }

    private static func defaultValue(from kind: CreateDatabaseFormSpec.FieldKind) -> String? {
        switch kind {
        case .picker(_, let defaultValue), .searchable(_, let defaultValue):
            return defaultValue
        }
    }
}
