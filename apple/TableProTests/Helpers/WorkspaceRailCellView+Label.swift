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

    /// The tile is its own view rather than the `imageView` outlet, for the same reason.
    var renderedTile: ConnectionTileView? {
        subviews.lazy.compactMap { $0 as? ConnectionTileView }.first
    }

    var renderedStatusMark: ConnectionStatusMarkView? {
        subviews.lazy.compactMap { $0 as? ConnectionStatusMarkView }.first
    }

    /// The badge on the tile's corner, the only image view the cell holds directly.
    var renderedTransactionBadge: NSImageView? {
        subviews.lazy.compactMap { $0 as? NSImageView }.first
    }
}

extension ConnectionStatusMarkView {
    var renderedTint: NSColor? {
        displayedTint
    }
}
