//
//  FindViewController.swift
//  CodeEditSourceEditor
//
//  Created by Khan Winter on 3/10/25.
//

import AppKit
import CodeEditTextView

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
    var findPanel: FindPanelHostingView
    var findPanelVerticalConstraint: NSLayoutConstraint!

    /// The 'real' top padding amount.
    /// Is equal to ``topPadding`` if set, or the view's top safe area inset if not.
    var resolvedTopPadding: CGFloat {
        (topPadding ?? view.safeAreaInsets.top)
    }

    init(target: FindPanelTarget, childView: NSView) {
        viewModel = FindPanelViewModel(target: target)
        self.childView = childView
        findPanel = FindPanelHostingView(viewModel: viewModel)
        super.init(nibName: nil, bundle: nil)
        viewModel.dismiss = { [weak self] in
            self?.hideFindPanel()
        }
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func loadView() {
        super.loadView()

        // Set up the `childView` as a subview of our view. Constrained to all edges, except the top is constrained to
        // the find panel's bottom
        // The find panel is constrained to the top of the view.
        // The find panel's top anchor when hidden, is equal to it's negated height hiding it above the view's contents.
        // When visible, it's set to 0.

        view.clipsToBounds = false
        view.addSubview(findPanel)
        view.addSubview(childView)

        // Ensure find panel is always on top
        findPanel.wantsLayer = true
        findPanel.layer?.zPosition = 1000

        findPanelVerticalConstraint = findPanel.topAnchor.constraint(equalTo: view.topAnchor)

        NSLayoutConstraint.activate([
            // Constrain find panel
            findPanelVerticalConstraint,
            findPanel.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            findPanel.trailingAnchor.constraint(equalTo: view.trailingAnchor),

            // Constrain child view
            childView.topAnchor.constraint(equalTo: view.topAnchor),
            childView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            childView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            childView.trailingAnchor.constraint(equalTo: view.trailingAnchor)
        ])
    }

    override func viewWillAppear() {
        super.viewWillAppear()
        if viewModel.isShowingFindPanel { // Update constraints for initial state
            findPanel.isHidden = false
            setFindPanelConstraintShow()
        } else {
            findPanel.isHidden = true
            setFindPanelConstraintHide()
        }
    }
}
