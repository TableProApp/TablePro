//
//  TextMutation+isEmpty.swift
//  CodeEditSourceEditor
//
//  Created by Khan Winter on 3/1/24.
//

import TextStory

extension TextMutation {
    /// Determines if the mutation is an empty mutation.
    ///
    /// Will return `true` if the mutation is neither a delete operation nor an insert operation.
    var isEmpty: Bool {
        self.string.isEmpty && self.range.isEmpty
    }
}
