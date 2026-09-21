//
//  MainSplitViewController+TrailingPane.swift
//  TablePro
//

import AppKit
import Combine

/// The window's one trailing pane: which surface it draws, and the commands that open, close and
/// switch it.
///
/// One split item, one autosave record and one 270pt floor for all three surfaces. A surface change
/// moves only which of the workspace's hosting controllers the item parents, and every question about
/// the pane is answered from `TrailingPaneSurfaceResolver`, through `trailingPaneCommandContext`, so
/// nothing here can report about a surface the window is not drawing. Four separate readings of the
/// stored surface used to disagree with the one that decided what was parented, and only that one knew
/// Agent mode imposes the result.
extension MainSplitViewController: TrailingPaneProxy {
    /// Everything the trailing-pane commands decide from, for the connection on screen.
    var trailingPaneCommandContext: TrailingPaneCommandResolver.Context {
        let selected = workspaces.selected
        return TrailingPaneCommandResolver.Context(
            contentMode: selected?.contentMode ?? .browse,
            storedSurface: selected?.trailingPaneState?.surface ?? .inspector,
            isPaneOpen: isTrailingPaneOpen,
            isAIEnabled: AppSettingsManager.shared.ai.enabled,
            hasContent: currentPane == .content
        )
    }

    /// Which surface a workspace's pane draws, whether or not it is the one on screen: the answer
    /// decides which of its hosting controllers is parented when it is selected.
    func resolvedTrailingSurface(for workspace: ConnectionWorkspace) -> TrailingPaneSurface {
        TrailingPaneSurfaceResolver.resolve(
            stored: workspace.trailingPaneState?.surface ?? .inspector,
            contentMode: workspace.contentMode,
            isAIEnabled: AppSettingsManager.shared.ai.enabled
        )
    }

    var isTrailingPaneOpen: Bool {
        guard let inspectorSplitItem else { return false }
        return !inspectorSplitItem.isCollapsed
    }

    var isInspectorVisible: Bool {
        trailingPaneCommandContext.isShowing(.inspector)
    }

    var isAssistantVisible: Bool {
        trailingPaneCommandContext.isShowing(.assistant)
    }

    /// Opening a trailing surface needs a session to put in it. Closing one the user already has
    /// open does not, and the window no longer takes it down on their behalf, so a connection that
    /// drops with the inspector open would otherwise leave an empty column with no command to
    /// close it.
    var canToggleTrailingPane: Bool {
        TrailingPaneCommandResolver.canTogglePane(trailingPaneCommandContext)
    }

    /// The assistant is the one surface a setting can take away, and the one Agent mode has no pane
    /// for, so its command goes with both rather than staying enabled over a pane that would refuse
    /// to open.
    var canToggleAssistant: Bool {
        TrailingPaneCommandResolver.canToggleAssistant(trailingPaneCommandContext)
    }

    func showInspector() {
        reveal(.inspector)
    }

    func showAssistant() {
        reveal(.assistant)
    }

    func hideTrailingPane() {
        inspectorSplitItem?.animator().isCollapsed = true
        recomputeWindowMinSize()
    }

    func toggleInspector() {
        perform(TrailingPaneCommandResolver.paneToggle(trailingPaneCommandContext))
    }

    func toggleAssistant() {
        guard let effect = TrailingPaneCommandResolver.assistantToggle(trailingPaneCommandContext) else { return }
        perform(effect)
    }

    /// Reveals without writing, so a pane that auto-show opened is not recorded as one the user
    /// chose. `revealsForSelection` says why it reads the stored surface.
    func revealInspectorForSelection() {
        guard TrailingPaneCommandResolver.revealsForSelection(trailingPaneCommandContext) else { return }
        presentTrailingPane()
    }

    /// Parents whichever surface the selected workspace is showing.
    ///
    /// Measured: swapping the hosted child of an inspector split item leaves its width exactly as
    /// the user dragged it, so a surface change costs a view swap and nothing else. Assigning
    /// `viewController` on the item itself instead would throw, which is why the pane is a
    /// container in the first place.
    func showSelectedTrailingPane() {
        let selected = workspaces.selected
        followStoredSurface(of: selected?.trailingPaneState)
        guard let selected else {
            inspectorPaneHost.show(nil)
            return
        }
        inspectorPaneHost.show(selected.panes.trailingPane(for: resolvedTrailingSurface(for: selected)))
    }

    /// The one writer of the stored surface besides the pane header's picker, and it writes only
    /// what `TrailingPaneCommandResolver.reveal` calls a choice.
    private func reveal(_ surface: TrailingPaneSurface) {
        let decision = TrailingPaneCommandResolver.reveal(surface, trailingPaneCommandContext)
        guard decision.opensPane else { return }
        if decision.storesChoice {
            workspaces.selected?.trailingPaneState?.surface = surface
        }
        presentTrailingPane()
    }

    private func presentTrailingPane() {
        rebuildTrailingPanes()
        showSelectedTrailingPane()
        inspectorSplitItem?.animator().isCollapsed = false
        recomputeWindowMinSize()
    }

    private func perform(_ effect: TrailingPaneCommandResolver.Effect) {
        switch effect {
        case .hide:
            hideTrailingPane()
        case .reveal(let surface):
            reveal(surface)
        }
    }

    /// Follows the stored surface of the connection on screen, which is what the pane header's
    /// picker writes, knowing nothing about the window.
    ///
    /// The new surface is parented on the next turn of the run loop, so the view whose segment was
    /// clicked leaves the window after the picker's action has returned rather than from inside it.
    /// `@Published` also announces a change before the value is stored, so a synchronous reparent
    /// would read the surface being replaced.
    private func followStoredSurface(of state: TrailingPaneState?) {
        guard state !== observedTrailingPaneState else { return }
        observedTrailingPaneState = state
        trailingSurfaceCancellable = state?.$surface
            .dropFirst()
            .removeDuplicates()
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                self?.parentStoredSurface()
            }
    }

    /// A reveal has already parented what it wrote, so this does nothing then. A header choice is
    /// drawn with the command actions the window has now, which the pane was built before, the same
    /// reason every reveal rebuilds the two surfaces first.
    private func parentStoredSurface() {
        guard let selected = workspaces.selected else { return }
        let target = selected.panes.trailingPane(for: resolvedTrailingSurface(for: selected))
        guard inspectorPaneHost.shown !== target else { return }
        rebuildTrailingPanes()
        showSelectedTrailingPane()
    }
}
