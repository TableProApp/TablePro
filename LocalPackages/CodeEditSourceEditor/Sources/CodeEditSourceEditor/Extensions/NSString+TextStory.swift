//
//  NSString+TextStory.swift
//  CodeEditSourceEditor
//
//  Created by Khan Winter on 6/3/25.
//

import AppKit
import TextStory

extension NSString: @retroactive TextStoring {
    public func substring(from range: NSRange) -> String? {
        self.substring(with: range)
    }

    public func applyMutation(_ mutation: TextMutation) {
        self.replacingCharacters(in: mutation.range, with: mutation.string)
    }
}
