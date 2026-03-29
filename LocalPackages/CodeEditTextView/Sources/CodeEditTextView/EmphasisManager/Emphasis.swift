//
//  Emphasis.swift
//  CodeEditTextView
//
//  Created by Khan Winter on 3/31/25.
//

import AppKit

/// Represents a single emphasis with its properties
public struct Emphasis: Equatable {
    /// The range the emphasis applies it's style to, relative to the entire text document.
    public let range: NSRange

    /// The style to apply emphasis with, handled by the ``EmphasisManager``.
    public let style: EmphasisStyle

    /// Set to `true` to 'flash' the emphasis before removing it automatically after being added.
    ///
    /// Useful when an emphasis should be temporary and quick, like when emphasizing paired brackets in a document.
    public let flash: Bool

    /// Set to `true` to style the emphasis as 'inactive'.
    ///
    /// When ``style`` is ``EmphasisStyle/standard``, this reduces shadows and background color.
    /// For all styles, if drawing text on top of them, this uses ``EmphasisManager/getInactiveTextColor`` instead of
    /// the text view's text color to render the emphasized text.
    public let inactive: Bool

    /// Set to `true` if the emphasis manager should update the text view's selected range to match
    /// this object's ``Emphasis/range`` value.
    public let selectInDocument: Bool

    public init(
        range: NSRange,
        style: EmphasisStyle = .standard,
        flash: Bool = false,
        inactive: Bool = false,
        selectInDocument: Bool = false
    ) {
        self.range = range
        self.style = style
        self.flash = flash
        self.inactive = inactive
        self.selectInDocument = selectInDocument
    }
}
