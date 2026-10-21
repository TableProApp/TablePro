//
//  UserTypeCreationDraft.swift
//  TablePro
//

import Foundation
import TableProPluginKit

/// What the New Type sheet holds. Every kind's members live side by side, so switching the kind
/// back and forth loses nothing the user typed.
struct UserTypeCreationDraft: Equatable {
    struct Field: Identifiable, Equatable {
        let id = UUID()
        var name = ""
        var type = ""
    }

    struct Check: Identifiable, Equatable {
        let id = UUID()
        var name = ""
        var expression = ""
    }

    struct Label: Identifiable, Equatable {
        let id = UUID()
        var name = ""
    }

    var kind: UserDefinedTypeInfo.Kind
    var schema: String?
    var name = ""
    var labels: [Label] = []
    var fields: [Field] = []
    var baseType = ""
    var defaultValue = ""
    var isNotNull = false
    var checks: [Check] = []
    var comment = ""

    init(kind: UserDefinedTypeInfo.Kind, schema: String?) {
        self.kind = kind
        self.schema = schema
    }

    private var trimmedName: String { name.trimmingCharacters(in: .whitespacesAndNewlines) }

    /// Why Create is unavailable, first problem first. Empty when the definition can be sent.
    var problems: [String] {
        var problems: [String] = []
        if trimmedName.isEmpty { problems.append(String(localized: "Name the type.")) }
        switch kind {
        case .enumeration:
            if labels.contains(where: { $0.name.isEmpty }) {
                problems.append(String(localized: "A label cannot be empty."))
            }
            if let duplicate = Self.firstDuplicate(labels.map(\.name)) {
                problems.append(String(format: String(localized: "“%@” is listed twice."), duplicate))
            }
        case .composite:
            if fields.contains(where: { $0.name.trimmingCharacters(in: .whitespaces).isEmpty }) {
                problems.append(String(localized: "Every field needs a name."))
            }
            if fields.contains(where: { $0.type.trimmingCharacters(in: .whitespaces).isEmpty }) {
                problems.append(String(localized: "A field needs a type."))
            }
            if let duplicate = Self.firstDuplicate(fields.map(\.name).filter { !$0.isEmpty }) {
                problems.append(String(format: String(localized: "“%@” is listed twice."), duplicate))
            }
        case .domain:
            if baseType.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                problems.append(String(localized: "Choose the base type."))
            }
            if checks.contains(where: { $0.expression.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) {
                problems.append(String(localized: "A check needs an expression."))
            }
            if let duplicate = Self.firstDuplicate(checks.map(\.name).filter { !$0.isEmpty }) {
                problems.append(String(format: String(localized: "“%@” is listed twice."), duplicate))
            }
        default:
            break
        }
        return problems
    }

    var definition: PluginUserDefinedTypeDefinition? {
        guard let pluginKind = kind.pluginKind else { return nil }
        let comment = comment.trimmingCharacters(in: .whitespacesAndNewlines)
        switch kind {
        case .enumeration:
            return PluginUserDefinedTypeDefinition(
                name: trimmedName, schema: schema, kind: pluginKind,
                enumLabels: labels.map(\.name),
                comment: comment.isEmpty ? nil : comment
            )
        case .composite:
            return PluginUserDefinedTypeDefinition(
                name: trimmedName, schema: schema, kind: pluginKind,
                fields: fields.map {
                    PluginUserDefinedTypeField(
                        name: $0.name.trimmingCharacters(in: .whitespaces),
                        type: $0.type.trimmingCharacters(in: .whitespaces)
                    )
                },
                comment: comment.isEmpty ? nil : comment
            )
        case .domain:
            let defaultValue = defaultValue.trimmingCharacters(in: .whitespacesAndNewlines)
            return PluginUserDefinedTypeDefinition(
                name: trimmedName, schema: schema, kind: pluginKind,
                baseType: baseType.trimmingCharacters(in: .whitespacesAndNewlines),
                defaultValue: defaultValue.isEmpty ? nil : defaultValue,
                isNotNull: isNotNull,
                checks: checks.map {
                    let name = $0.name.trimmingCharacters(in: .whitespaces)
                    return PluginUserDefinedTypeCheck(
                        name: name.isEmpty ? nil : name,
                        expression: $0.expression.trimmingCharacters(in: .whitespacesAndNewlines)
                    )
                },
                comment: comment.isEmpty ? nil : comment
            )
        default:
            return PluginUserDefinedTypeDefinition(name: trimmedName, schema: schema, kind: pluginKind)
        }
    }

    /// A complete definition of each kind, for asking a driver which kinds it can create.
    static func probeDefinition(kind: UserDefinedTypeInfo.Kind) -> PluginUserDefinedTypeDefinition? {
        var draft = UserTypeCreationDraft(kind: kind, schema: "s")
        draft.name = "t"
        draft.labels = [Label(name: "a")]
        draft.fields = [Field(name: "a", type: "integer")]
        draft.baseType = "integer"
        return draft.definition
    }

    private static func firstDuplicate(_ names: [String]) -> String? {
        var seen: Set<String> = []
        for name in names where !seen.insert(name).inserted {
            return name
        }
        return nil
    }
}
