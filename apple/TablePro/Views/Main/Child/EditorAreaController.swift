//
//  EditorAreaController.swift
//  TablePro
//

import AppKit
import SwiftUI

/// What the connection's editor area shows above the history drawer.
enum EditorAreaContent {
    case query(QueryTabInput)
    case view(AnyView)
}

struct QueryTabInput {
    var pane: QueryEditorPaneInput
    var results: AnyView
    var isResultsCollapsed: Binding<Bool>
    var resultsAutosaveName: String
}

struct EditorAreaInput {
    var content: EditorAreaContent
    var history: AnyView
    var isHistoryCollapsed: Binding<Bool>
    var historyAutosaveName: String
    var contentMinimumHeight: CGFloat
}

/// The query tab in AppKit: the editor pane over a collapsible results pane, SwiftUI only in the panes' leaves.
@MainActor
final class QueryTabSplitController {
    let split: CollapsibleSplitController
    let pane: QueryEditorPaneController
    private let results: NSHostingController<AnyView>
    private var isResultsCollapsed: Binding<Bool>

    init(input: QueryTabInput) {
        pane = QueryEditorPaneController(input: input.pane)
        results = NSHostingController(rootView: input.results)
        results.sizingOptions = []
        isResultsCollapsed = input.isResultsCollapsed
        split = CollapsibleSplitController(
            top: pane,
            bottom: results,
            autosaveName: input.resultsAutosaveName,
            isBottomCollapsed: input.isResultsCollapsed.wrappedValue
        )
        split.onUserCollapseChange = { [weak self] collapsed in
            guard let self, self.isResultsCollapsed.wrappedValue != collapsed else { return }
            self.isResultsCollapsed.wrappedValue = collapsed
        }
    }

    func apply(_ input: QueryTabInput) {
        isResultsCollapsed = input.isResultsCollapsed
        pane.apply(input.pane)
        results.rootView = input.results
        split.setBottomCollapsed(input.isResultsCollapsed.wrappedValue)
    }

    func teardown() {
        pane.teardown()
    }
}

/// The connection's editor area: the selected tab's content over the history drawer. It is AppKit down to the
/// panes because every SwiftUI host above the SQL editor made the window lay out each host again, nested, as the
/// editor's views went in; opening a connection on a saved query tab stalled the main thread for that.
@MainActor
final class EditorAreaController {
    let drawer: CollapsibleSplitController
    private let contentHost = WorkspacePaneHost()
    private let history: NSHostingController<AnyView>
    private var isHistoryCollapsed: Binding<Bool>
    private var querySplit: QueryTabSplitController?
    private var otherContent: NSHostingController<AnyView>?

    init(input: EditorAreaInput) {
        history = NSHostingController(rootView: input.history)
        history.sizingOptions = []
        isHistoryCollapsed = input.isHistoryCollapsed
        drawer = CollapsibleSplitController(
            top: contentHost,
            bottom: history,
            autosaveName: input.historyAutosaveName,
            topMinimumThickness: input.contentMinimumHeight,
            bottomMinimumThickness: 180,
            isBottomCollapsed: input.isHistoryCollapsed.wrappedValue
        )
        drawer.onUserCollapseChange = { [weak self] collapsed in
            guard let self, self.isHistoryCollapsed.wrappedValue != collapsed else { return }
            self.isHistoryCollapsed.wrappedValue = collapsed
        }
        show(input.content)
    }

    func apply(_ input: EditorAreaInput) {
        isHistoryCollapsed = input.isHistoryCollapsed
        show(input.content)
        history.rootView = input.history
        drawer.setBottomCollapsed(input.isHistoryCollapsed.wrappedValue)
    }

    func teardown() {
        querySplit?.teardown()
        querySplit = nil
        contentHost.show(nil)
        otherContent = nil
    }

    private func show(_ content: EditorAreaContent) {
        switch content {
        case .query(let input):
            if let querySplit {
                querySplit.apply(input)
            } else {
                querySplit = QueryTabSplitController(input: input)
            }
            contentHost.show(querySplit?.split)
            otherContent = nil
        case .view(let view):
            if let otherContent {
                otherContent.rootView = view
            } else {
                let host = NSHostingController(rootView: view)
                host.sizingOptions = []
                otherContent = host
            }
            contentHost.show(otherContent)
            // Torn down rather than kept, as before: the editor latches a new query tab's focus and saved selection
            // only while it goes into the window, so a kept editor would leave both unapplied.
            querySplit?.teardown()
            querySplit = nil
        }
    }
}

/// The one SwiftUI boundary of the editor area.
struct EditorAreaHost: NSViewControllerRepresentable {
    let input: EditorAreaInput

    final class Coordinator {
        var area: EditorAreaController?
    }

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeNSViewController(context: Context) -> CollapsibleSplitController {
        let area = EditorAreaController(input: input)
        context.coordinator.area = area
        return area.drawer
    }

    func updateNSViewController(_ controller: CollapsibleSplitController, context: Context) {
        context.coordinator.area?.apply(input)
    }

    static func dismantleNSViewController(_ controller: CollapsibleSplitController, coordinator: Coordinator) {
        coordinator.area?.teardown()
        coordinator.area = nil
    }

    // The area fills what it is offered; measuring it would lay out every pane it holds.
    func sizeThatFits(
        _ proposal: ProposedViewSize,
        nsViewController: CollapsibleSplitController,
        context: Context
    ) -> CGSize? {
        proposal.replacingUnspecifiedDimensions()
    }
}
