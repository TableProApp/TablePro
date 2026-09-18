//
//  StructureFooterPolicy.swift
//  TablePro
//
//  What the add/remove pair under a structure list offers, and why it is dimmed when it is.
//

import Foundation
import TableProPluginKit

/// The single decision behind the "+" and "-" under the Structure tab's list.
///
/// Pure and SwiftUI-free so the rule is testable, and one function so the label, the enabled state
/// and the tooltip can never disagree. They did: the labels came from one switch, the enabled state
/// from a second that read engine capability flags alone, and the tooltip from a third that returned
/// nil for every tab but Foreign Keys. So a view offered an enabled "Add Column" over an
/// `ALTER TABLE … ADD COLUMN` PostgreSQL always refuses, with nothing to explain it. (#2726)
enum StructureFooterPolicy {
    /// Nil for a tab with nothing to add: DDL is text, Parts is read-only, and a trigger is created
    /// through its own editor rather than by typing a row.
    static func operation(forAdding tab: StructureTab) -> StructureEditOperation? {
        switch tab {
        case .columns: return .addColumn
        case .indexes: return .addIndex
        case .foreignKeys: return .addForeignKey
        case .checkConstraints: return .addCheckConstraint
        case .ddl, .parts, .triggers: return nil
        }
    }

    static func operation(forRemoving tab: StructureTab) -> StructureEditOperation? {
        switch tab {
        case .columns: return .dropColumn
        case .indexes: return .dropIndex
        case .foreignKeys: return .dropForeignKey
        case .checkConstraints: return .dropCheckConstraint
        case .ddl, .parts, .triggers: return nil
        }
    }

    static func labels(for tab: StructureTab) -> (add: String, remove: String)? {
        switch tab {
        case .columns:
            return (String(localized: "Add Column"), String(localized: "Remove Column"))
        case .indexes:
            return (String(localized: "Add Index"), String(localized: "Remove Index"))
        case .foreignKeys:
            return (String(localized: "Add Foreign Key"), String(localized: "Remove Foreign Key"))
        case .checkConstraints:
            return (String(localized: "Add Check Constraint"), String(localized: "Remove Check Constraint"))
        case .ddl, .parts, .triggers:
            return nil
        }
    }

    /// - Parameter resolve: The full availability of one operation, which the caller supplies because
    ///   it owns the connection the engine half of the answer comes from.
    ///
    /// A refusing object kind keeps the pair on screen and dims it with the reason, the way the
    /// Foreign Keys tab already did. An engine that cannot edit structure at all hides it instead:
    /// there is nothing to explain per object when the whole tab is read-only.
    static func resolve(
        tab: StructureTab,
        canEditSchema: Bool,
        hasSelection: Bool,
        resolve: (StructureEditOperation) -> StructureEditAvailability
    ) -> StructureFooterCapability {
        guard canEditSchema,
              let labels = labels(for: tab),
              let adding = operation(forAdding: tab),
              let removing = operation(forRemoving: tab)
        else {
            return StructureFooterCapability()
        }

        let addAvailability = resolve(adding)
        let removeAvailability = resolve(removing)

        return StructureFooterCapability(
            canAdd: addAvailability.isAvailable,
            canRemove: hasSelection && removeAvailability.isAvailable,
            addLabel: labels.add,
            removeLabel: labels.remove,
            /// Never the absence of a selection. The pair dims while nothing is selected on every
            /// tab and on every engine, which needs no sentence; only a refusal the user could not
            /// have predicted does.
            unavailableReason: addAvailability.unavailableReason ?? removeAvailability.unavailableReason
        )
    }
}
