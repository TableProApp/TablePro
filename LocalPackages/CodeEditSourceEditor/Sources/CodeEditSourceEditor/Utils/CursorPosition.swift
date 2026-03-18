//
//  CursorPosition.swift
//  CodeEditSourceEditor
//
//  Created by Khan Winter on 11/13/23.
//

import Foundation

/// # Cursor Position
///
/// Represents the position of a cursor in a document.
/// Provides information about the range of the selection relative to the document, and the line-column information.
/// 
/// Can be initialized by users without knowledge of either column and line position or range in the document.
/// When initialized by users, certain values may be set to `NSNotFound` or `-1` until they can be filled in by the text
/// controller.
/// 
public struct CursorPosition: Sendable, Codable, Equatable, Hashable {
    public struct Position: Sendable, Codable, Equatable, Hashable {
        /// The line the cursor is located at. 1-indexed.
        /// If ``CursorPosition/range`` is not empty, this is the line at the beginning of the selection.
        public let line: Int
        /// The column the cursor is located at. 1-indexed.
        /// If ``CursorPosition/range`` is not empty, this is the column at the beginning of the selection.
        public let column: Int

        public init(line: Int, column: Int) {
            self.line = line
            self.column = column
        }

        var isPositive: Bool { line > 0 && column > 0 }
    }

    /// Initialize a cursor position.
    ///
    /// When this initializer is used, ``CursorPosition/range`` will be initialized to `NSNotFound`.
    /// The range value, however, be filled when updated by ``SourceEditor`` via a `Binding`, or when it appears
    /// in the``TextViewController/cursorPositions`` array.
    ///
    /// - Parameters:
    ///   - line: The line of the cursor position, 1-indexed.
    ///   - column: The column of the cursor position, 1-indexed.
    public init(line: Int, column: Int) {
        self.range = .notFound
        self.start = Position(line: line, column: column)
        self.end = nil
    }

    public init(start: Position, end: Position?) {
        self.range = .notFound
        self.start = start
        self.end = end
    }

    /// Initialize a cursor position.
    ///
    /// When this initializer is used, both ``CursorPosition/line`` and ``CursorPosition/column`` will be initialized
    /// to `-1`. They will, however, be filled when updated by ``SourceEditor`` via a `Binding`, or when it
    /// appears in the ``TextViewController/cursorPositions`` array.
    ///
    /// - Parameter range: The range of the cursor position.
    public init(range: NSRange) {
        self.range = range
        self.start = Position(line: -1, column: -1)
        self.end = nil
    }

    /// Private initializer.
    /// - Parameters:
    ///   - range: The range of the position.
    ///   - start: The start position of the range.
    ///   - end: The end position of the range.
    init(range: NSRange, start: Position, end: Position?) {
        self.range = range
        self.start = start
        self.end = end
    }

    /// The range of the selection.
    public let range: NSRange
    public let start: Position
    public let end: Position?
}
