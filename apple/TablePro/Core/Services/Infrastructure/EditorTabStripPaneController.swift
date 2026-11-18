//
//  EditorTabStripPaneController.swift
//  TablePro
//

import AppKit
import Combine

@MainActor
internal final class EditorTabStripPaneController: NSViewController {
    internal let stripView = EditorTabStripView()

    private var subscriptions: Set<AnyCancellable> = []
    private var execution: TabExecutionObservation?

    override internal func loadView() {
        view = stripView
        preferredContentSize = CGSize(width: 0, height: EditorTabStripLayout.bandHeight)
    }

    internal func bind(
        tabManager: QueryTabManager,
        execution: TabExecutionObservation,
        target: ContainerSwitchTarget?,
        commands: EditorTabCommands
    ) {
        subscriptions.removeAll()
        self.execution = execution
        stripView.commands = commands

        let refresh = { [weak self, weak tabManager, weak execution] in
            guard let self, let tabManager, let execution else { return }
            self.stripView.apply(EditorTabStripSnapshot.items(
                tabs: tabManager.visibleTabs,
                selectedId: tabManager.selectedTab?.id,
                target: target,
                isBusy: { execution.isBusy($0) }
            ))
        }
        tabManager.onMainActorChange(refresh).store(in: &subscriptions)
        execution.onMainActorChange(refresh).store(in: &subscriptions)
        refresh()
    }

    internal func unbind() {
        subscriptions.removeAll()
        execution = nil
        stripView.commands = nil
        stripView.apply([])
    }

    internal func teardown() {
        unbind()
        view.removeFromSuperview()
        removeFromParent()
    }
}
