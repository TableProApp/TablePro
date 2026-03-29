//
//  TextLineStorage+Iterator.swift
//  CodeEditTextView
//
//  Created by Khan Winter on 7/16/23.
//

import Foundation

/// # Dev Note
///
/// For these iterators, prefer `.getLine(atIndex: )` for finding the next item in the iteration.
/// Using plain indexes instead of y positions or ranges has led to far fewer edge cases.
public extension TextLineStorage {
    /// Iterate over all lines overlapping a range of `y` positions. Positions in the middle of line contents will
    /// return that line.
    /// - Parameters:
    ///   - minY: The minimum y position to start at.
    ///   - maxY: The maximum y position to stop at.
    /// - Returns: A lazy iterator for retrieving lines.
    func linesStartingAt(_ minY: CGFloat, until maxY: CGFloat) -> TextLineStorageYIterator {
        TextLineStorageYIterator(storage: self, minY: minY, maxY: maxY)
    }

    /// Iterate over all lines overlapping a range in the document.
    /// - Parameter range: The range to query.
    /// - Returns: A lazy iterator for retrieving lines.
    func linesInRange(_ range: NSRange) -> TextLineStorageRangeIterator {
        TextLineStorageRangeIterator(storage: self, range: range)
    }

    struct TextLineStorageYIterator: LazySequenceProtocol, IteratorProtocol {
        private let storage: TextLineStorage
        private let minY: CGFloat
        private let maxY: CGFloat
        private var currentPosition: TextLinePosition?

        init(storage: TextLineStorage, minY: CGFloat, maxY: CGFloat, currentPosition: TextLinePosition? = nil) {
            self.storage = storage
            self.minY = minY
            self.maxY = maxY
            self.currentPosition = currentPosition
        }

        public mutating func next() -> TextLinePosition? {
            if let currentPosition {
                guard let nextPosition = storage.getLine(atIndex: currentPosition.index + 1),
                      nextPosition.yPos < maxY else {
                    return nil
                }
                self.currentPosition = nextPosition
                return nextPosition
            } else if let nextPosition = storage.getLine(atPosition: minY) {
                self.currentPosition = nextPosition
                return nextPosition
            } else {
                return nil
            }
        }
    }

    struct TextLineStorageRangeIterator: LazySequenceProtocol, IteratorProtocol {
        private let storage: TextLineStorage
        private let range: NSRange
        private var currentPosition: TextLinePosition?

        init(storage: TextLineStorage, range: NSRange, currentPosition: TextLinePosition? = nil) {
            self.storage = storage
            self.range = range
            self.currentPosition = currentPosition
        }

        public mutating func next() -> TextLinePosition? {
            if let currentPosition {
                guard currentPosition.range.max < range.max,
                      let nextPosition = storage.getLine(atIndex: currentPosition.index + 1) else {
                    return nil
                }
                self.currentPosition = nextPosition
                return nextPosition
            } else if let nextPosition = storage.getLine(atOffset: range.location) {
                self.currentPosition = nextPosition
                return nextPosition
            } else {
                return nil
            }
        }
    }
}

extension TextLineStorage: LazySequenceProtocol {
    public func makeIterator() -> TextLineStorageIterator {
        TextLineStorageIterator(storage: self, currentPosition: nil)
    }

    public struct TextLineStorageIterator: IteratorProtocol {
        private let storage: TextLineStorage
        private var currentPosition: TextLinePosition?

        init(storage: TextLineStorage, currentPosition: TextLinePosition? = nil) {
            self.storage = storage
            self.currentPosition = currentPosition
        }

        public mutating func next() -> TextLinePosition? {
            if let currentPosition {
                guard currentPosition.range.max < storage.length,
                      let nextPosition = storage.getLine(atIndex: currentPosition.index + 1) else {
                    return nil
                }
                self.currentPosition = nextPosition
                return nextPosition
            } else if let nextPosition = storage.getLine(atOffset: 0) {
                self.currentPosition = nextPosition
                return nextPosition
            } else {
                return nil
            }
        }
    }
}
