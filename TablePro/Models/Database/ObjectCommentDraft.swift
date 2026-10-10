//
//  ObjectCommentDraft.swift
//  TablePro
//

import Foundation

/// Empty or whitespace-only text removes the comment rather than storing it, which is what PostgreSQL
/// itself does with an empty string.
internal struct ObjectCommentDraft: Equatable {
    internal let original: String?
    internal var text: String

    internal init(original: String?) {
        let normalized = Self.normalized(original)
        self.original = normalized
        self.text = normalized ?? ""
    }

    /// Nil removes the comment.
    internal var commentToSave: String? {
        Self.normalized(text)
    }

    internal var hasChanges: Bool {
        commentToSave != original
    }

    internal var removesComment: Bool {
        original != nil && commentToSave == nil
    }

    internal static func normalized(_ comment: String?) -> String? {
        guard let comment, !comment.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return comment
    }
}
