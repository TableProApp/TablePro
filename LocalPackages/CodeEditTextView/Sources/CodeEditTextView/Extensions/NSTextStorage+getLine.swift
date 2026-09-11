//
//  NSTextStorage+getLine.swift
//  CodeEditTextView
//
//  Created by Khan Winter on 9/3/23.
//

import AppKit

extension NSString {
    private static let lineFeed: unichar = 0x0A
    private static let carriageReturn: unichar = 0x0D
    private static let lineBreakCharacters = CharacterSet(charactersIn: "\r\n")

    func getNextLine(startingAt location: Int) -> NSRange? {
        guard location >= 0, location < length else { return nil }
        if location > 0,
           character(at: location) == Self.lineFeed,
           character(at: location - 1) == Self.carriageReturn {
            return NSRange(location: location - 1, length: 2)
        }
        let searchRange = NSRange(location: location, length: length - location)
        let found = rangeOfCharacter(from: Self.lineBreakCharacters, options: .literal, range: searchRange)
        guard found.location != NSNotFound else { return nil }
        let isCarriageReturnLineFeed = character(at: found.location) == Self.carriageReturn
            && found.location + 1 < length
            && character(at: found.location + 1) == Self.lineFeed
        return NSRange(location: found.location, length: isCarriageReturnLineFeed ? 2 : 1)
    }

    fileprivate func lineStartBreakingAtLineEndings(before location: Int) -> Int {
        var cursor = min(max(location, 0), length)
        if cursor > 0, cursor < length,
           character(at: cursor) == Self.lineFeed,
           character(at: cursor - 1) == Self.carriageReturn {
            cursor -= 1
        }
        let searchRange = NSRange(location: 0, length: cursor)
        let found = rangeOfCharacter(
            from: Self.lineBreakCharacters,
            options: [.literal, .backwards],
            range: searchRange
        )
        return found.location == NSNotFound ? 0 : NSMaxRange(found)
    }
}

public extension NSString {
    func lineRangeBreakingAtLineEndings(for range: NSRange) -> NSRange {
        let start = lineStartBreakingAtLineEndings(before: range.location)
        let endAnchor = max(range.location, NSMaxRange(range) - (range.length > 0 ? 1 : 0))
        guard let terminator = getNextLine(startingAt: endAnchor) else {
            return NSRange(location: start, length: length - start)
        }
        return NSRange(location: start, length: NSMaxRange(terminator) - start)
    }
}

extension NSTextStorage {
    func getNextLine(startingAt location: Int) -> NSRange? {
        (self.string as NSString).getNextLine(startingAt: location)
    }
}
