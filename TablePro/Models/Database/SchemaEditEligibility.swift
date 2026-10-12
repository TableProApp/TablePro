//
//  SchemaEditEligibility.swift
//  TablePro
//

import Foundation

/// Which rows offer New Schema and Edit Schema.
///
/// A sibling of `ObjectRenameEligibility` and `ContainerDropEligibility`, and asked the same way:
/// the menu never offers what the engine cannot do or the gate would refuse, so the user does not
/// meet a failure alert for something the menu promised.
enum SchemaEditEligibility {
    struct Context {
        let supportsCreateSchema: Bool
        let supportsSchemaOwner: Bool
        let supportsSchemaPrivileges: Bool
        let supportsRenameSchema: Bool
        let isReadOnly: Bool
    }

    static func canCreate(context: Context) -> Bool {
        !context.isReadOnly && context.supportsCreateSchema
    }

    /// Editing needs something to edit. An engine that makes schemas but exposes no owner, no
    /// privileges and no rename has nothing to put in the sheet, so the item stays off the menu
    /// rather than opening an empty one.
    static func editable(_ targets: [DatabaseContainerRef], context: Context) -> DatabaseContainerRef? {
        guard !context.isReadOnly, hasEditableFacet(context) else { return nil }
        /// One at a time, for the same reason Rename is: a sheet edits one schema, so offering the
        /// item over a multi-row selection would silently act on a row the user did not mean.
        guard targets.count == 1, let target = targets.first else { return nil }
        guard target.kind == .schema, !target.isSystem, target.schema != nil else { return nil }
        return target
    }

    static func hasEditableFacet(_ context: Context) -> Bool {
        context.supportsSchemaOwner || context.supportsSchemaPrivileges || context.supportsRenameSchema
    }
}
