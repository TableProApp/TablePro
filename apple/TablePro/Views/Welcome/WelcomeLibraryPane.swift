//
//  WelcomeLibraryPane.swift
//  TablePro
//

import SwiftUI

// No `.toolbar` or `.searchable` here: bridged into the window they cost the first frame about 100 ms.
internal struct WelcomeLibraryPane: View {
    @ObservedObject var viewModel: WelcomeViewModel

    var body: some View {
        content
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .onAppear {
                viewModel.setUp()
            }
            .modifier(WelcomePresentations(vm: viewModel) { viewModel.focusList() })
    }

    @ViewBuilder
    private var content: some View {
        switch viewModel.listState {
        case .content:
            WelcomeOutlineView(viewModel: viewModel, revision: viewModel.outlineRevision)
        case .firstRun:
            EmptyStateView(
                icon: "cylinder.split.1x2",
                title: String(localized: "No Connections"),
                description: String(localized: "Connect to your own database, or open the sample database to look around."),
                actionTitle: String(localized: "Open Sample Database"),
                action: { viewModel.openSampleDatabase() },
                secondaryActionTitle: viewModel.hasImportableApp ? String(localized: "Import from Other App…") : nil,
                secondaryAction: viewModel.hasImportableApp ? { viewModel.importConnectionsFromApp() } : nil
            )
        case .noSearchMatch(let term):
            UnavailableStateView.search(text: term)
        case .noFilterMatch:
            EmptyStateView(
                icon: "tag",
                title: String(localized: "No Matching Connections"),
                description: String(localized: "No connections have the selected tags."),
                actionTitle: String(localized: "Clear Filters"),
                action: { viewModel.clearTagFilters() }
            )
        }
    }
}
