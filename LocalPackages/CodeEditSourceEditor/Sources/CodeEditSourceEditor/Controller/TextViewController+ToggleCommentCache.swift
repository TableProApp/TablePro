//
//  File.swift
//  
//
//  Created by Tommy Ludwig on 23.08.24.
//

import CodeEditTextView

extension TextViewController {
    /// A cache used to store and manage comment-related information for lines in a text view.
    /// This class helps in efficiently inserting or removing comment characters at specific line positions.
    struct CommentCache: ~Copyable {
        /// Holds necessary information like the lines range
        var lineInfos: [TextLineStorage<TextLine>.TextLinePosition?] = []
        /// Caches the content of lines by their indices. Populated only if comment characters need to be inserted.
        var lineStrings: [Int: String] = [:]
        /// Caches the shift range factors for lines based on their indices.
        var shiftRangeFactors: [Int: Int] = [:]
        /// Insertion is necessary only if at least one of the selected
        /// lines does not already start with `startCommentChars`.
        var shouldInsertCommentChars: Bool = false
        var startCommentChars: String?
        /// The characters used to end a comment.
        /// This is applicable for languages (e.g., HTML)
        /// that require a closing comment sequence at the end of the line.
        var endCommentChars: String?
    }
}
