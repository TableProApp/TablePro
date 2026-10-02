//
//  WorkspaceRailCellView+Label.swift
//  TableProTests
//

import AppKit
@testable import TablePro

extension WorkspaceRailCellView {
    /// The cell keeps its label out of the `textField` outlet, because a source list restyles that
    /// outlet, so tests find the label among the subviews instead.
    var renderedLabel: NSTextField? {
        subviews.lazy.compactMap { $0 as? NSTextField }.first
    }
}
