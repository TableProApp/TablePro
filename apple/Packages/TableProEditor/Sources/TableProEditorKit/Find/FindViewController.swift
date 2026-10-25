//
//  FindViewController.swift
//  TableProEditorKit
//
//  Created by Khan Winter on 3/10/25.
//

import AppKit
import TableProTextEngine

/// Creates a container controller for displaying and hiding a find panel with a content view.
final class FindViewController: NSViewController {
    var viewModel: FindPanelViewModel

    /// The amount of padding from the top of the view to inset the find panel by.
    /// When set, the safe area is ignored, and the top padding is measured from the top of the view's frame.
    var topPadding: CGFloat? {
        didSet {
            if viewModel.isShowingFindPanel {
                setFindPanelConstraintShow()
            }
        }
    }

    var childView: NSView
    // Built on first show, as NSTextFinder builds its find bar: a hidden hosting view is still laid out, and
    // SwiftUI inserting its controls forces a layout of the whole editor around them.
    private(set) var findPanel: FindPanelHostingView?
    private(set) var findPanelVerticalConstraint: NSLayoutConstraint?

    /// The 'real' top padding amount.
    /// Is equal to ``topPadding`` if set, or the view's top safe area inset if not.
    var resolvedTopPadding: CGFloat {
        (topPadding ?? view.safeAreaInsets.top)
    }

    init(target: FindPanelTarget, childView: NSView) {
        viewModel = FindPanelViewModel(target: target)
        self.childView = childView
        super.init(nibName: nil, bundle: nil)
        viewModel.dismiss = { [weak self] in
            self?.hideFindPanel()
        }
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func loadView() { // swiftlint:disable:this prohibited_super_call
        /// See `PlainControllerView`: `super` looks for a nib on macOS 13 and raises.
        if #available(macOS 14.0, *) {
            super.loadView()
        } else {
            view = PlainControllerView.make()
        }

        /// The editor's outermost view, so the one place that keeps it inside its own frame. `NSView.clipsToBounds`
        /// defaults to NO from macOS 14 (NSView.h), and nothing below this view clips on its own: AppKit moves the
        /// gutter, a floating subview, into a `_NSScrollViewFloatingSubviewsContainerView` beside the clip view, and
        /// neither that container nor `NSScrollView` clips. The gutter is document-tall, so the line numbers of rows
        /// scrolled out of view painted over whatever the host stacked above the editor, and the find panel sliding
        /// in from above and back out did the same. Clipping here also bounds the gutter's `visibleRect`, which
        /// scopes its hover tracking and the ribbons' accessibility elements.
        view.clipsToBounds = true
        view.addSubview(childView)

        NSLayoutConstraint.activate([
            childView.topAnchor.constraint(equalTo: view.topAnchor),
            childView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            childView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            childView.trailingAnchor.constraint(equalTo: view.trailingAnchor)
        ])
    }

    override func viewWillAppear() {
        super.viewWillAppear()
        guard viewModel.isShowingFindPanel else { return }
        installFindPanel().isHidden = false
        setFindPanelConstraintShow()
    }

    @discardableResult
    func installFindPanel() -> FindPanelHostingView {
        if let findPanel { return findPanel }
        let panel = FindPanelHostingView(viewModel: viewModel)
        // Ordered above the content so the panel wins hit-testing as well as drawing.
        // `zPosition` alone only affects drawing, which left clicks falling through to the
        // text view underneath.
        view.addSubview(panel, positioned: .above, relativeTo: childView)
        panel.wantsLayer = true
        let top = panel.topAnchor.constraint(equalTo: view.topAnchor)
        NSLayoutConstraint.activate([
            top,
            panel.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            panel.trailingAnchor.constraint(equalTo: view.trailingAnchor)
        ])
        findPanel = panel
        findPanelVerticalConstraint = top
        setFindPanelConstraintHide()
        // The panel's onChange searches a term typed into it; one set before it existed has not been searched.
        if !viewModel.findText.isEmpty {
            viewModel.find()
        }
        return panel
    }
}
