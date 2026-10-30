//
//  RoutineDebugChooserSheet.swift
//  TablePro
//

import SwiftUI
import TableProPluginKit

// Debug > Debug Routine…: every unit the driver can debug in the browsed schema, packages included where the engine has them.
internal struct RoutineDebugChooserSheet: View {
    private enum LoadState {
        case loading
        case failed(String)
        case loaded([Row])
    }

    private struct Row: Identifiable {
        let target: PluginDebugTarget
        var id: String { target.identity }
    }

    let load: @MainActor () async throws -> [PluginDebugTarget]
    let onFinish: @MainActor (PluginDebugTarget?) -> Void

    @State private var loadState: LoadState = .loading
    @State private var searchText = ""
    @State private var selection: Row.ID?

    static func present(
        on window: NSWindow,
        setup: RoutineDebugSetup,
        load: @escaping @MainActor () async throws -> [PluginDebugTarget]
    ) async -> PluginDebugTarget? {
        await RoutineDebugSheet.present(on: window, setup: setup) { finish in
            RoutineDebugChooserSheet(load: load, onFinish: finish)
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            Divider()
            footer
        }
        .frame(width: 520, height: 420)
        .task { await reload() }
    }

    private var header: some View {
        HStack(spacing: 16) {
            Text(String(localized: "Debug Routine"))
                .font(.headline)
            Spacer()
            NativeSearchField(
                text: $searchText,
                placeholder: String(localized: "Search"),
                accessibilityIdentifier: "routine-debug-chooser-search"
            )
            .frame(width: 180)
        }
        .padding(20)
    }

    @ViewBuilder
    private var content: some View {
        switch loadState {
        case .loading:
            ProgressView()
        case .failed(let message):
            UnavailableStateView {
                Label(String(localized: "Can't List Routines"), systemImage: "exclamationmark.triangle")
            } description: {
                Text(message)
            } actions: {
                Button(String(localized: "Try Again")) {
                    Task { await reload() }
                }
            }
        case .loaded(let rows) where rows.isEmpty:
            UnavailableStateView(String(localized: "Nothing to Debug"), systemImage: "ladybug")
        case .loaded:
            if filteredRows.isEmpty {
                UnavailableStateView.search(text: searchText)
            } else {
                Table(filteredRows, selection: $selection) {
                    TableColumn(String(localized: "Name")) { row in
                        Text(row.target.name)
                    }
                    TableColumn(String(localized: "Kind")) { row in
                        Text(row.target.kindDisplayName)
                    }
                    .width(min: 80, ideal: 120, max: 200)
                }
                .contextMenu(forSelectionType: Row.ID.self) { _ in
                    EmptyView()
                } primaryAction: { identities in
                    if let identity = identities.first { choose(identity) }
                }
            }
        }
    }

    private var footer: some View {
        HStack {
            Spacer()
            Button(String(localized: "Cancel")) {
                onFinish(nil)
            }
            .keyboardShortcut(.cancelAction)
            Button(String(localized: "Debug…")) {
                if let selection { choose(selection) }
            }
            .keyboardShortcut(.defaultAction)
            .disabled(selection == nil)
        }
        .padding(20)
    }

    private var filteredRows: [Row] {
        guard case .loaded(let rows) = loadState else { return [] }
        let query = searchText.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else { return rows }
        return rows.filter { $0.target.name.localizedCaseInsensitiveContains(query) }
    }

    private func choose(_ identity: Row.ID) {
        guard let row = filteredRows.first(where: { $0.id == identity }) else { return }
        onFinish(row.target)
    }

    private func reload() async {
        loadState = .loading
        do {
            let targets = try await load()
            loadState = .loaded(
                targets
                    .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
                    .map(Row.init(target:))
            )
        } catch {
            loadState = .failed(RoutineDebugController.message(for: error))
        }
    }
}
