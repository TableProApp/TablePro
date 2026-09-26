//
//  WelcomeLibraryPane.swift
//  TablePro
//

import AppKit
import Combine
import SwiftUI
import TableProConnectionLibrary

@MainActor
internal final class WelcomeToolbarPresentation: ObservableObject {
    @Published internal var labelMode: WelcomeToolbarLabelMode = .iconOnly
}

internal enum WelcomeToolbarLabelMode: CaseIterable, Hashable, Identifiable {
    case iconAndText
    case iconOnly

    internal var id: Self { self }

    internal var title: String {
        switch self {
        case .iconAndText:
            String(localized: "Icon and Text")
        case .iconOnly:
            String(localized: "Icon Only")
        }
    }
}

internal struct WelcomeLibraryPane: View {
    @ObservedObject var viewModel: WelcomeViewModel
    @ObservedObject var toolbarPresentation: WelcomeToolbarPresentation

    var body: some View {
        content
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .searchable(
                text: $viewModel.searchText,
                tokens: $viewModel.searchTokens,
                suggestedTokens: suggestedTokens,
                placement: .toolbar,
                prompt: Text("Search Connections")
            ) { token in
                Label(token.name, systemImage: "tag")
            }
            .onSubmit(of: .search) {
                viewModel.focusList(selectFirstRow: true)
            }
            .toolbar {
                WelcomeLibraryToolbar(
                    viewModel: viewModel,
                    toolbarPresentation: toolbarPresentation
                )
            }
            .onAppear {
                viewModel.setUp()
            }
            .modifier(WelcomePresentations(vm: viewModel) { viewModel.focusList() })
    }

    private var suggestedTokens: Binding<[WelcomeTagToken]> {
        Binding(
            get: { viewModel.suggestedTokens },
            set: { _ in }
        )
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
                action: { viewModel.searchTokens.removeAll() }
            )
        }
    }
}

internal struct WelcomeLibraryToolbar: ToolbarContent {
    let viewModel: WelcomeViewModel
    @ObservedObject var toolbarPresentation: WelcomeToolbarPresentation

    var body: some ToolbarContent {
        ToolbarItem(placement: .primaryAction) {
            Button {
                WindowOpener.shared.openConnectionForm()
            } label: {
                WelcomeToolbarActionLabel(
                    title: String(localized: "New Connection"),
                    systemImage: "plus",
                    labelMode: toolbarPresentation.labelMode
                )
            }
            .help(newConnectionHelp)
            .accessibilityIdentifier("welcome-toolbar-new-connection")
        }

        if #available(macOS 26.0, *) {
            ToolbarSpacer(.fixed, placement: .primaryAction)
        }

        ToolbarItem(placement: .primaryAction) {
            Button {
                viewModel.requestNewGroup(parentId: nil, movingConnectionIds: [])
            } label: {
                WelcomeToolbarActionLabel(
                    title: String(localized: "New Group"),
                    systemImage: "folder.badge.plus",
                    labelMode: toolbarPresentation.labelMode
                )
            }
            .help(String(localized: "New Group"))
            .accessibilityIdentifier("welcome-toolbar-new-group")
        }

        if #available(macOS 26.0, *) {
            ToolbarSpacer(.fixed, placement: .primaryAction)
        }

        ToolbarItem(placement: .primaryAction) {
            WelcomeViewOptionsMenu(
                viewModel: viewModel,
                toolbarPresentation: toolbarPresentation
            )
        }
    }

    private var newConnectionHelp: String {
        let binding = AppSettingsManager.shared.keyboard.shortcut(for: .newConnection)
        guard let displayString = binding?.displayString, !displayString.isEmpty else {
            return String(localized: "New Connection")
        }
        return String(format: String(localized: "New Connection (%@)"), displayString)
    }
}

internal struct WelcomeToolbarActionLabel: View {
    let title: String
    let systemImage: String
    let labelMode: WelcomeToolbarLabelMode

    @ViewBuilder
    var body: some View {
        switch labelMode {
        case .iconAndText:
            label.labelStyle(WelcomeToolbarTitleAndIconLabelStyle())
        case .iconOnly:
            label.labelStyle(.iconOnly)
        }
    }

    private var label: some View {
        Label(title, systemImage: systemImage)
    }
}

internal struct WelcomeToolbarTitleAndIconLabelStyle: LabelStyle {
    internal static let spacing: CGFloat = 6

    internal func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: Self.spacing) {
            configuration.icon
            configuration.title
        }
    }
}

internal struct WelcomeViewOptionsMenu: View {
    @ObservedObject var viewModel: WelcomeViewModel
    @ObservedObject var toolbarPresentation: WelcomeToolbarPresentation

    var body: some View {
        Menu {
            Picker(String(localized: "Sort By"), selection: sortSelection) {
                ForEach(WelcomeSortOption.allCases, id: \.self) { option in
                    Text(option.title).tag(option.mode)
                }
            }
            .pickerStyle(.menu)

            Picker(String(localized: "Toolbar"), selection: $toolbarPresentation.labelMode) {
                ForEach(WelcomeToolbarLabelMode.allCases) { mode in
                    Text(mode.title).tag(mode)
                }
            }
            .pickerStyle(.menu)

            if !viewModel.availableTags.isEmpty {
                Section(String(localized: "Filter by Tag")) {
                    ForEach(viewModel.availableTags) { tag in
                        Toggle(isOn: tokenBinding(for: tag)) {
                            Label {
                                Text(tag.name)
                            } icon: {
                                Image(nsImage: ConnectionLibrarySymbols.tagImage(for: tag.color) ?? NSImage())
                            }
                        }
                    }
                }

                if viewModel.searchTokens.count > 1 {
                    Picker(String(localized: "Match"), selection: $viewModel.tagMatch) {
                        Text("Any Selected Tag").tag(LibraryTagMatch.any)
                        Text("All Selected Tags").tag(LibraryTagMatch.all)
                    }
                    .pickerStyle(.inline)
                }

                if !viewModel.searchTokens.isEmpty {
                    Button(String(localized: "Clear Filters")) {
                        viewModel.searchTokens.removeAll()
                    }
                }
            }
        } label: {
            Label(String(localized: "View Options"), systemImage: "line.3.horizontal.decrease.circle")
        }
        .help(String(localized: "Sort and filter connections"))
        .accessibilityIdentifier("welcome-toolbar-view-options")
    }

    private var sortSelection: Binding<LibrarySortMode> {
        Binding(
            get: { viewModel.sortMode },
            set: { viewModel.setSortMode($0) }
        )
    }

    private func tokenBinding(for tag: ConnectionTag) -> Binding<Bool> {
        Binding(
            get: { viewModel.searchTokens.contains { $0.id == tag.id } },
            set: { isOn in
                if isOn {
                    guard !viewModel.searchTokens.contains(where: { $0.id == tag.id }) else { return }
                    viewModel.searchTokens.append(WelcomeViewModel.token(for: tag))
                } else {
                    viewModel.searchTokens.removeAll { $0.id == tag.id }
                }
            }
        )
    }
}
