//
//  LineEnding.swift
//  CodeEditTextView
//
//  Created by Khan Winter on 8/16/23.
//

import AppKit

public enum LineEnding: String, CaseIterable {
    /// The default unix `\n` character
    case lineFeed = "\n"
    /// MacOS line ending `\r` character
    case carriageReturn = "\r"
    /// Windows line ending sequence `\r\n`
    case carriageReturnLineFeed = "\r\n"

    /// Initialize a line ending from a line string.
    /// - Parameter line: The line to use
    public init?(line: String) {
        guard let lastChar = line.last,
              let lineEnding = LineEnding(rawValue: String(lastChar)) else { return nil }
        self = lineEnding
    }

    /// Attempts to detect the line ending from a line storage.
    /// - Parameter lineStorage: The line storage to enumerate.
    /// - Returns: A line ending. Defaults to `.lf` if none could be found.
    public static func detectLineEnding(
        lineStorage: TextLineStorage<TextLine>,
        textStorage: NSTextStorage
    ) -> LineEnding {
        var histogram: [LineEnding: Int] = LineEnding.allCases.reduce(into: [LineEnding: Int]()) {
            $0[$1] = 0
        }
        var shouldContinue = true
        var lineIterator = lineStorage.makeIterator()

        while let line = lineIterator.next(), shouldContinue {
            guard let lineString = textStorage.substring(from: line.range),
                  let lineEnding = LineEnding(line: lineString) else {
                continue
            }
            histogram[lineEnding] = histogram[lineEnding]! + 1
            // after finding 15 lines of a line ending we assume it's correct.
            if histogram[lineEnding]! >= 15 {
                shouldContinue = false
            }
        }

        let orderedValues = histogram.sorted(by: { $0.value > $1.value })
        // Return the max of the histogram, but if there's no max
        // we default to lineFeed. This should be a parameter in the future.
        if orderedValues.count >= 2 {
            if orderedValues[0].value == orderedValues[1].value {
                return .lineFeed
            } else {
                return orderedValues[0].key
            }
        } else {
            return .lineFeed
        }
    }

    /// The UTF-16 Length of the line ending.
    public var length: Int {
        rawValue.utf16.count
    }
}
