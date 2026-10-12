//
//  StructureTableCommentPolicy.swift
//  TablePro
//

import Foundation

internal enum StructureTableCommentPolicy {
    internal struct Field: Equatable {
        internal var isEditable: Bool
        internal var placeholder: String
        internal var unavailableReason: String?
    }

    /// Nil hides the bar: the engine has no comment statement for this kind of object.
    internal static func resolve(
        objectKind: TableInfo.TableType,
        support: DatabaseObjectToolEligibility.Support,
        isReadOnly: Bool,
        load: MetadataLoadPhase,
        isSaving: Bool
    ) -> Field? {
        guard support.commentableTypes.contains(objectKind) else { return nil }
        let placeholder = String(localized: "Optional")
        if isSaving {
            return Field(isEditable: false, placeholder: placeholder, unavailableReason: StructureFooterPolicy.savingReason)
        }
        switch load {
        case .idle, .loading:
            return Field(isEditable: false, placeholder: placeholder, unavailableReason: nil)
        case .failed(let message):
            return Field(
                isEditable: false,
                placeholder: String(localized: "Comment Unavailable"),
                unavailableReason: message
            )
        case .loaded:
            break
        }
        guard DatabaseObjectToolEligibility.canEditComment(objectKind, support: support, isReadOnly: isReadOnly) else {
            return Field(
                isEditable: false,
                placeholder: placeholder,
                unavailableReason: String(
                    localized: "Cannot save schema changes: TablePro's Safe Mode is set to read-only for this connection."
                )
            )
        }
        return Field(isEditable: true, placeholder: placeholder, unavailableReason: nil)
    }
}
