//
//  StatementRun.swift
//  CodeEditSourceEditor
//

import Foundation

/// One span of the document the gutter offers to run on its own.
///
/// The editor knows nothing about what a statement is or what running one means. The host finds the spans, hands them
/// over, and is called back with the one whose control was pressed.
public struct StatementRun: Equatable, Sendable {
    /// The span this control runs, in UTF-16 units, relative to the whole document.
    public let range: NSRange

    public init(range: NSRange) {
        self.range = range
    }
}
