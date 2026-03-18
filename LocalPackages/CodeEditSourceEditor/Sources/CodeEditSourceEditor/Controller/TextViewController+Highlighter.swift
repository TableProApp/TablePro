//
//  TextViewController+Highlighter.swift
//  CodeEditSourceEditor
//
//  Created by Khan Winter on 10/14/23.
//

import Foundation
import SwiftTreeSitter

extension TextViewController {
    package func setUpHighlighter() {
        if let highlighter {
            textView.removeStorageDelegate(highlighter)
            self.highlighter = nil
        }

        let highlighter = Highlighter(
            textView: textView,
            minimapView: minimapView,
            providers: highlightProviders,
            attributeProvider: self,
            language: language
        )
        textView.addStorageDelegate(highlighter)
        self.highlighter = highlighter
    }

    /// Sets new highlight providers. Recognizes when objects move in the array or are removed or inserted.
    ///
    /// This is in place of a setter on the ``highlightProviders`` variable to avoid wasting resources setting up
    /// providers early.
    ///
    /// - Parameter newProviders: All the new providers.
    package func setHighlightProviders(_ newProviders: [HighlightProviding]) {
        highlighter?.setProviders(newProviders)
        highlightProviders = newProviders
    }
}

extension TextViewController: ThemeAttributesProviding {
    public func attributesFor(_ capture: CaptureName?) -> [NSAttributedString.Key: Any] {
        [
            .font: configuration.appearance.theme.fontFor(for: capture, from: font),
            .foregroundColor: configuration.appearance.theme.colorFor(capture),
            .kern: textView.kern
        ]
    }
}
