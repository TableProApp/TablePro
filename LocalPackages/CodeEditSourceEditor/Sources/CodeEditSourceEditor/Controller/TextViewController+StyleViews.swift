//
//  TextViewController+StyleViews.swift
//  CodeEditSourceEditor
//
//  Created by Khan Winter on 7/3/24.
//

import AppKit
import CodeEditTextView

extension TextViewController {
    package func generateParagraphStyle() -> NSMutableParagraphStyle {
        // swiftlint:disable:next force_cast
        let paragraph = NSParagraphStyle.default.mutableCopy() as! NSMutableParagraphStyle
        paragraph.tabStops.removeAll()
        paragraph.defaultTabInterval = CGFloat(tabWidth) * font.charWidth
        return paragraph
    }

    /// Style the text view.
    package func styleTextView() {
        textView.postsFrameChangedNotifications = true
        if wrapLines {
            textView.translatesAutoresizingMaskIntoConstraints = false
        } else {
            textView.translatesAutoresizingMaskIntoConstraints = true
            textView.autoresizingMask = [.height]
            textView.updateFrameIfNeeded()
        }
    }

    /// Style the scroll view.
    package func styleScrollView() {
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.contentView.postsFrameChangedNotifications = true
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = !wrapLines
        scrollView.scrollerStyle = .overlay
    }

    package func styleMinimapView() {
        minimapView.postsFrameChangedNotifications = true
    }

    /// Updates all relevant content insets including the find panel, scroll view, minimap and gutter position.
    package func updateContentInsets() {
        updateFloatingSubviewInsets()

        scrollView.contentView.postsBoundsChangedNotifications = true
        if let contentInsets = configuration.layout.contentInsets {
            scrollView.automaticallyAdjustsContentInsets = false
            scrollView.contentInsets = contentInsets

            minimapView.scrollView.automaticallyAdjustsContentInsets = false
            minimapView.scrollView.contentInsets.top = contentInsets.top
            minimapView.scrollView.contentInsets.bottom = contentInsets.bottom
        } else {
            scrollView.automaticallyAdjustsContentInsets = true
            minimapView.scrollView.automaticallyAdjustsContentInsets = true
        }

        // `additionalTextInsets` only effects text content.
        let additionalTextInsets = configuration.layout.additionalTextInsets
        scrollView.contentInsets.top += additionalTextInsets?.top ?? 0
        scrollView.contentInsets.bottom += additionalTextInsets?.bottom ?? 0
        minimapView.scrollView.contentInsets.top += additionalTextInsets?.top ?? 0
        minimapView.scrollView.contentInsets.bottom += additionalTextInsets?.bottom ?? 0

        // Inset the top by the find panel height
        let findInset: CGFloat = if findViewController?.viewModel.isShowingFindPanel ?? false {
            findViewController?.viewModel.panelHeight ?? 0
        } else {
            0
        }
        scrollView.contentInsets.top += findInset
        minimapView.scrollView.contentInsets.top += findInset

        findViewController?.topPadding = configuration.layout.contentInsets?.top

        gutterView.frame.origin.y = textView.frame.origin.y - scrollView.contentInsets.top

        // Update scrollview tiling
        scrollView.reflectScrolledClipView(scrollView.contentView)
        minimapView.scrollView.reflectScrolledClipView(minimapView.scrollView.contentView)
    }

    /// Reserves the gutter's and the minimap's widths on the scroll view. See ``floatingSubviewInsets``.
    ///
    /// The reservation changes the width the text has to fill, which the text view does not hear about on its own when
    /// only the trailing side moves, so its frame is brought up to date here.
    func updateFloatingSubviewInsets() {
        // Allow this method to be called before ``loadView()``
        guard scrollView != nil, textView != nil, gutterView != nil, minimapView != nil else { return }
        let insets = floatingSubviewInsets
        guard scrollView.floatingSubviewInsets != insets else { return }
        scrollView.floatingSubviewInsets = insets
        textView.updateFrameIfNeeded()
        reformattingGuideView?.updatePosition(in: self)
    }
}
