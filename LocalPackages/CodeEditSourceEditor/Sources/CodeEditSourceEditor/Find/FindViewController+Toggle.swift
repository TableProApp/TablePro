//
//  FindViewController+Toggle.swift
//  CodeEditSourceEditor
//
//  Created by Austin Condiff on 4/3/25.
//

import AppKit

extension FindViewController {
    /// Show the find panel
    ///
    /// Performs the following:
    /// - Makes the find panel the first responder.
    /// - Sets the find panel to be just outside the visible area (`resolvedTopPadding - FindPanel.height`).
    /// - Animates the find panel into position (resolvedTopPadding).
    /// - Makes the find panel the first responder.
    func showFindPanel(animated: Bool = true) {
        if viewModel.isShowingFindPanel {
            // If panel is already showing, just focus the text field
            viewModel.isFocused = true
            return
        }

        if viewModel.mode == .replace {
            viewModel.mode = .find
        }

        viewModel.isShowingFindPanel = true

        // Smooth out the animation by placing the find panel just outside the correct position before animating.
        findPanel.isHidden = false
        findPanelVerticalConstraint.constant = resolvedTopPadding - viewModel.panelHeight

        view.layoutSubtreeIfNeeded()

        // Perform the animation
        conditionalAnimated(animated) {
            // SwiftUI breaks things here, and refuses to return the correct `findPanel.fittingSize` so we
            // are forced to use a constant number.
            viewModel.target?.findPanelWillShow(panelHeight: viewModel.panelHeight)
            setFindPanelConstraintShow()
        } onComplete: { }

        viewModel.isFocused = true
        findPanel.addEventMonitor()

        NotificationCenter.default.post(
            name: FindPanelViewModel.Notifications.didToggle,
            object: viewModel.target
        )
    }

    /// Hide the find panel
    ///
    /// Performs the following:
    /// - Resigns the find panel from first responder.
    /// - Animates the find panel just outside the visible area (`resolvedTopPadding - FindPanel.height`).
    /// - Hides the find panel.
    /// - Sets the text view to be the first responder.
    func hideFindPanel(animated: Bool = true) {
        viewModel.isShowingFindPanel = false
        _ = findPanel.resignFirstResponder()
        findPanel.removeEventMonitor()

        conditionalAnimated(animated) {
            viewModel.target?.findPanelWillHide(panelHeight: viewModel.panelHeight)
            setFindPanelConstraintHide()
        } onComplete: { [weak self] in
            self?.findPanel.isHidden = true
            self?.viewModel.isFocused = false
        }

        // Set first responder back to text view
        if let target = viewModel.target {
            _ = target.findPanelTargetView.window?.makeFirstResponder(target.findPanelTargetView)
        }

        NotificationCenter.default.post(
            name: FindPanelViewModel.Notifications.didToggle,
            object: viewModel.target
        )
    }

    /// Performs an animation with a completion handler, conditionally animating the changes.
    /// - Parameters:
    ///   - animated: Determines if the changes are performed in an animation context.
    ///   - animatable: Perform the changes to be animated in this callback. Implicit animation will be enabled.
    ///   - onComplete: Called when the changes are complete, animated or not.
    private func conditionalAnimated(_ animated: Bool, animatable: () -> Void, onComplete: @escaping () -> Void) {
        if animated {
            withAnimation(animatable, onComplete: onComplete)
        } else {
            animatable()
            onComplete()
        }
    }

    /// Runs the `animatable` callback in an animation context with implicit animation enabled.
    /// - Parameter animatable: The callback run in the animation context. Perform layout or view updates in this
    ///                         callback to have them animated.
    private func withAnimation(_ animatable: () -> Void, onComplete: @escaping () -> Void) {
        NSAnimationContext.runAnimationGroup { animator in
            animator.duration = 0.15
            animator.allowsImplicitAnimation = true

            animatable()

            view.updateConstraints()
            view.layoutSubtreeIfNeeded()
        } completionHandler: {
            onComplete()
        }
    }

    /// Sets the find panel constraint to show the find panel.
    /// Can be animated using implicit animation.
    func setFindPanelConstraintShow() {
        // Update the find panel's top to be equal to the view's top.
        findPanelVerticalConstraint.constant = resolvedTopPadding
        findPanelVerticalConstraint.isActive = true
    }

    /// Sets the find panel constraint to hide the find panel.
    /// Can be animated using implicit animation.
    func setFindPanelConstraintHide() {
        // Update the find panel's top anchor to be equal to it's negative height, hiding it above the view.

        // SwiftUI hates us. It refuses to move views outside of the safe are if they don't have the `.ignoresSafeArea`
        // modifier, but with that modifier on it refuses to allow it to be animated outside the safe area.
        // The only way I found to fix it was to multiply the height by 3 here.
        findPanelVerticalConstraint.constant = resolvedTopPadding - (viewModel.panelHeight * 3)
        findPanelVerticalConstraint.isActive = true
    }
}
