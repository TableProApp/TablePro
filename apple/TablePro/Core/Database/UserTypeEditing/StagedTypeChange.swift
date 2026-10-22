//
//  StagedTypeChange.swift
//  TablePro
//

import Foundation
import TableProPluginKit

/// One change queued in a type's tab. The id survives reordering and removal, so an error the server
/// returned for it stays on the row that caused it.
struct StagedTypeChange: Identifiable, Equatable, Sendable {
    let id: UUID
    let change: PluginUserDefinedTypeChange

    init(id: UUID = UUID(), change: PluginUserDefinedTypeChange) {
        self.id = id
        self.change = change
    }

    /// A drop, or a field whose stored values are converted, cannot be taken back by queuing the
    /// opposite change, so the gate confirms it at every Safe Mode level.
    var isDestructive: Bool {
        switch change {
        case .dropField, .dropConstraint, .changeFieldType:
            return true
        default:
            return false
        }
    }

    /// The single change a property edit replaces rather than appends to.
    var property: Property? {
        switch change {
        case .rename: return .name
        case .setComment: return .comment
        case .setDefault: return .defaultValue
        case .setNotNull: return .notNull
        default: return nil
        }
    }

    enum Property: Equatable, Sendable {
        case name
        case comment
        case defaultValue
        case notNull
    }

    var summary: String {
        switch change {
        case .rename(let name):
            return String(format: String(localized: "Rename to “%@”"), name)
        case .setComment(let comment):
            guard let comment, !comment.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                return String(localized: "Remove the comment")
            }
            return String(localized: "Set the comment")
        case .addEnumLabel(let label, let placement):
            guard let placement else { return String(format: String(localized: "Add label “%@” at the end"), label) }
            return placement.placesBefore
                ? String(format: String(localized: "Add label “%1$@” before “%2$@”"), label, placement.anchor)
                : String(format: String(localized: "Add label “%1$@” after “%2$@”"), label, placement.anchor)
        case .renameEnumLabel(let oldLabel, let newLabel):
            return String(format: String(localized: "Rename label “%1$@” to “%2$@”"), oldLabel, newLabel)
        case .setDefault(let value):
            guard let value, !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                return String(localized: "Remove the default")
            }
            return String(format: String(localized: "Set the default to %@"), value)
        case .setNotNull(let isNotNull):
            return isNotNull ? String(localized: "Refuse NULL") : String(localized: "Allow NULL")
        case .addCheck(let check, let validates):
            let name = check.name?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let base = name.isEmpty
                ? String(format: String(localized: "Add check %@"), check.expression)
                : String(format: String(localized: "Add check “%1$@”: %2$@"), name, check.expression)
            guard !validates else { return base }
            return String(format: String(localized: "%@, without checking stored values"), base)
        case .dropConstraint(let name):
            return String(format: String(localized: "Drop constraint “%@”"), name)
        case .validateConstraint(let name):
            return String(format: String(localized: "Validate constraint “%@”"), name)
        case .addField(let field):
            return String(format: String(localized: "Add field “%1$@” %2$@"), field.name, field.type)
        case .dropField(let name):
            return String(format: String(localized: "Drop field “%@”"), name)
        case .renameField(let oldName, let newName):
            return String(format: String(localized: "Rename field “%1$@” to “%2$@”"), oldName, newName)
        case .changeFieldType(let field, let type):
            return String(format: String(localized: "Change field “%1$@” to %2$@"), field, type)
        @unknown default:
            return String(localized: "Change")
        }
    }
}
