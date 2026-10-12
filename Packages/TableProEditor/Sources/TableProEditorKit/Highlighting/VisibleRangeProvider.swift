//
//  VisibleRangeProvider.swift
//  TableProEditorKit
//
//  Created by Khan Winter on 10/13/24.
//

import AppKit
import TableProTextEngine

@MainActor
protocol VisibleRangeProviderDelegate: AnyObject {
    func visibleSetDidUpdate(_ newIndices: IndexSet)
}

/// Provides information to ``HighlightProviderState``s about what text is visible in the editor. Keeps it's contents
/// in sync with a text view and notifies listeners about changes so highlights can be applied to newly visible indices.
@MainActor
class VisibleRangeProvider {
    private weak var textView: TextView?
    weak var delegate: VisibleRangeProviderDelegate?

    var documentRange: NSRange {
        textView?.documentRange ?? .notFound
    }

    /// The set of visible indexes in the text view
    lazy var visibleSet: IndexSet = {
        IndexSet(integersIn: textView?.visibleTextRange ?? NSRange())
    }()

    init(textView: TextView) {
        self.textView = textView

        if let scrollView = textView.enclosingScrollView {
            NotificationCenter.default.addObserver(
                self,
                selector: #selector(visibleTextChanged),
                name: NSView.frameDidChangeNotification,
                object: scrollView
            )

            NotificationCenter.default.addObserver(
                self,
                selector: #selector(visibleTextChanged),
                name: NSView.boundsDidChangeNotification,
                object: scrollView.contentView
            )
        }

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(visibleTextChanged),
            name: NSView.frameDidChangeNotification,
            object: textView
        )
    }

    /// Updates the view to highlight newly visible text when the textview is scrolled or bounds change.
    @objc func visibleTextChanged() {
        guard let textViewVisibleRange = textView?.visibleTextRange else {
            return
        }
        self.visibleSet = IndexSet(integersIn: textViewVisibleRange)
        delegate?.visibleSetDidUpdate(visibleSet)
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }
}
