//
//  InvisibleCharactersConfig.swift
//  CodeEditTextView
//
//  Created by Khan Winter on 6/9/25.
//

import Foundation
import AppKit

public enum InvisibleCharacterStyle: Hashable {
    case replace(replacementCharacter: String, color: NSColor, font: NSFont)
    case emphasize(color: NSColor)
}

public protocol InvisibleCharactersDelegate: AnyObject {
    var triggerCharacters: Set<UInt16> { get }
    func invisibleStyleShouldClearCache() -> Bool
    func invisibleStyle(for character: UInt16, at range: NSRange, lineRange: NSRange) -> InvisibleCharacterStyle?
}
