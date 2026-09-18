//
//  ObjectCommentDraft.swift
//  TablePro
//

import Foundation

/// The text in the Edit Comment sheet and what saving it would write.
///
/// A comment that is empty or only whitespace is removed rather than stored, which is what an empty
/// field means to the person clearing it and what PostgreSQL itself does with an empty string.
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

    private static func normalized(_ comment: String?) -> String? {
        guard let comment, !comment.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return comment
    }
}
