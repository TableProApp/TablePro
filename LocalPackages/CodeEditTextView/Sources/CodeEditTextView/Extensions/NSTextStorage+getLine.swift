//
//  NSTextStorage+getLine.swift
//  CodeEditTextView
//
//  Created by Khan Winter on 9/3/23.
//

import AppKit

extension NSString {
    func getNextLine(startingAt location: Int) -> NSRange? {
        let range = NSRange(location: location, length: 0)
        var end: Int = NSNotFound
        var contentsEnd: Int = NSNotFound
        self.getLineStart(nil, end: &end, contentsEnd: &contentsEnd, for: range)
        if end != NSNotFound && contentsEnd != NSNotFound && end != contentsEnd {
            return NSRange(start: contentsEnd, end: end)
        } else {
            return nil
        }
    }
}

extension NSTextStorage {
    func getNextLine(startingAt location: Int) -> NSRange? {
        (self.string as NSString).getNextLine(startingAt: location)
    }
}
