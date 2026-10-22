//
//  UserTypeDraft.swift
//  TablePro
//

import Foundation
import TableProPluginKit

/// The server's copy with the queue applied in order. A change that no longer fits, such as a label
/// placed after one whose addition left the queue, is skipped and reported against its id.
struct UserTypeDraft: Equatable {
    enum Origin: Equatable {
        /// On the server, under this name.
        case existing(String)
        /// Added by the queued change with this id.
        case added(UUID)
    }

    struct Label: Identifiable, Equatable {
        let origin: Origin
        var name: String

        var id: String { Self.id(for: origin) }

        var originalName: String? {
            if case .existing(let name) = origin { return name }
            return nil
        }

        var isRenamed: Bool { originalName.map { $0 != name } ?? false }

        static func id(for origin: Origin) -> String {
            switch origin {
            case .existing(let name): return "existing:\(name)"
            case .added(let id): return "added:\(id.uuidString)"
            }
        }
    }

    struct Field: Identifiable, Equatable {
        let origin: Origin
        var name: String
        var type: String
        let originalType: String?
        let collation: String?
        var isDropped = false

        var id: String { Label.id(for: origin) }

        var originalName: String? {
            if case .existing(let name) = origin { return name }
            return nil
        }

        var isRenamed: Bool { originalName.map { $0 != name } ?? false }
        var isRetyped: Bool { originalType.map { $0 != type } ?? false }
    }

    struct Constraint: Identifiable, Equatable {
        let origin: Origin
        let name: String
        /// The catalog's definition for an existing check, the typed expression for a new one.
        let text: String
        var isValidated: Bool
        var isDropped = false
        var isValidationQueued = false

        var id: String { Label.id(for: origin) }
    }

    var name: String
    var comment: String?
    var labels: [Label]
    var fields: [Field]
    var defaultValue: String?
    var isNotNull: Bool
    var constraints: [Constraint]

    init(_ type: UserDefinedTypeInfo) {
        name = type.name
        comment = type.comment
        labels = type.enumLabels.map { Label(origin: .existing($0), name: $0) }
        fields = type.fields.map {
            Field(origin: .existing($0.name), name: $0.name, type: $0.type, originalType: $0.type, collation: $0.collation)
        }
        defaultValue = type.defaultValue
        isNotNull = type.isNotNull
        constraints = type.constraints.map {
            Constraint(origin: .existing($0.name), name: $0.name, text: $0.definition, isValidated: $0.isValidated)
        }
    }

    var liveFields: [Field] { fields.filter { !$0.isDropped } }
    var liveConstraints: [Constraint] { constraints.filter { !$0.isDropped } }

    struct Projection: Equatable {
        let draft: UserTypeDraft
        /// Why a queued change cannot run where it stands, by change id.
        let issues: [UUID: String]
    }

    static func project(_ type: UserDefinedTypeInfo, changes: [StagedTypeChange]) -> Projection {
        var draft = UserTypeDraft(type)
        var issues: [UUID: String] = [:]
        for staged in changes {
            if let issue = draft.apply(staged, kind: type.kind) {
                issues[staged.id] = issue
            }
        }
        return Projection(draft: draft, issues: issues)
    }

    private mutating func apply(_ staged: StagedTypeChange, kind: UserDefinedTypeInfo.Kind) -> String? {
        switch staged.change {
        case .rename(let newName):
            guard let newName = Self.nonEmpty(newName) else { return Self.emptyName }
            name = newName
        case .setComment(let value):
            comment = Self.nonEmpty(value)
        case .addEnumLabel(let label, let placement):
            guard kind == .enumeration else { return Self.wrongKind }
            guard !label.isEmpty else { return String(localized: "A label cannot be empty.") }
            guard !labels.contains(where: { $0.name == label }) else { return Self.duplicateLabel(label) }
            let entry = Label(origin: .added(staged.id), name: label)
            guard let placement else {
                labels.append(entry)
                return nil
            }
            guard let anchor = labels.firstIndex(where: { $0.name == placement.anchor }) else {
                return Self.missingLabel(placement.anchor)
            }
            labels.insert(entry, at: placement.placesBefore ? anchor : anchor + 1)
        case .renameEnumLabel(let oldLabel, let newLabel):
            guard kind == .enumeration else { return Self.wrongKind }
            guard let index = labels.firstIndex(where: { $0.name == oldLabel }) else { return Self.missingLabel(oldLabel) }
            guard !newLabel.isEmpty else { return String(localized: "A label cannot be empty.") }
            guard !labels.contains(where: { $0.name == newLabel }) else { return Self.duplicateLabel(newLabel) }
            labels[index].name = newLabel
        case .setDefault(let value):
            guard kind == .domain else { return Self.wrongKind }
            defaultValue = Self.nonEmpty(value)
        case .setNotNull(let value):
            guard kind == .domain else { return Self.wrongKind }
            isNotNull = value
        case .addCheck(let check, let validates):
            guard kind == .domain else { return Self.wrongKind }
            guard Self.nonEmpty(check.expression) != nil else {
                return String(localized: "A check needs an expression.")
            }
            let checkName = Self.nonEmpty(check.name) ?? ""
            if !checkName.isEmpty, liveConstraints.contains(where: { $0.name == checkName }) {
                return Self.duplicateConstraint(checkName)
            }
            constraints.append(Constraint(
                origin: .added(staged.id), name: checkName, text: check.expression, isValidated: validates
            ))
        case .dropConstraint(let constraint):
            guard let index = liveConstraintIndex(constraint) else { return Self.missingConstraint(constraint) }
            constraints[index].isDropped = true
        case .validateConstraint(let constraint):
            guard let index = liveConstraintIndex(constraint) else { return Self.missingConstraint(constraint) }
            guard !constraints[index].isValidated else {
                return String(format: String(localized: "“%@” is already validated."), constraint)
            }
            constraints[index].isValidated = true
            constraints[index].isValidationQueued = true
        case .addField(let field):
            guard kind == .composite else { return Self.wrongKind }
            guard !field.name.isEmpty else { return Self.emptyName }
            guard Self.nonEmpty(field.type) != nil else { return String(localized: "A field needs a type.") }
            guard liveFieldIndex(field.name) == nil else { return Self.duplicateField(field.name) }
            fields.append(Field(
                origin: .added(staged.id), name: field.name, type: field.type, originalType: nil, collation: field.collation
            ))
        case .dropField(let field):
            guard let index = liveFieldIndex(field) else { return Self.missingField(field) }
            fields[index].isDropped = true
        case .renameField(let oldName, let newName):
            guard let index = liveFieldIndex(oldName) else { return Self.missingField(oldName) }
            guard !newName.isEmpty else { return Self.emptyName }
            guard liveFieldIndex(newName) == nil else { return Self.duplicateField(newName) }
            fields[index].name = newName
        case .changeFieldType(let field, let newType):
            guard let index = liveFieldIndex(field) else { return Self.missingField(field) }
            guard Self.nonEmpty(newType) != nil else { return String(localized: "A field needs a type.") }
            fields[index].type = newType
        @unknown default:
            return Self.wrongKind
        }
        return nil
    }

    private func liveFieldIndex(_ name: String) -> Int? {
        fields.firstIndex { !$0.isDropped && $0.name == name }
    }

    private func liveConstraintIndex(_ name: String) -> Int? {
        constraints.firstIndex { !$0.isDropped && !$0.name.isEmpty && $0.name == name }
    }

    static func nonEmpty(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : value
    }

    private static var emptyName: String { String(localized: "A name cannot be empty.") }
    private static var wrongKind: String { String(localized: "This change does not apply to this kind of type.") }

    private static func duplicateLabel(_ label: String) -> String {
        String(format: String(localized: "“%@” is already a label."), label)
    }

    private static func missingLabel(_ label: String) -> String {
        String(format: String(localized: "“%@” is not a label any more."), label)
    }

    private static func duplicateField(_ field: String) -> String {
        String(format: String(localized: "“%@” is already a field."), field)
    }

    private static func missingField(_ field: String) -> String {
        String(format: String(localized: "“%@” is not a field any more."), field)
    }

    private static func duplicateConstraint(_ constraint: String) -> String {
        String(format: String(localized: "“%@” is already a constraint."), constraint)
    }

    private static func missingConstraint(_ constraint: String) -> String {
        String(format: String(localized: "“%@” is not a constraint any more."), constraint)
    }
}
