//
//  DatabaseSearchSheet.swift
//  TablePro
//

import SwiftUI

internal struct DatabaseSearchSheet: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject internal var session: DatabaseSearchSession
    internal let onOpen: (DatabaseSearchTableResult) -> Void

    internal init(session: DatabaseSearchSession, onOpen: @escaping (DatabaseSearchTableResult) -> Void) {
        self.session = session
        self.onOpen = onOpen
    }

    internal var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            content
            Divider()
            footer
        }
        .frame(width: 720, height: 520)
        .task { await session.loadTablesIfNeeded() }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(String(localized: "Search Database"))
                .font(.title3.weight(.semibold))
            Text(session.scopeDescription)
                .font(.callout)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(20)
    }

    @ViewBuilder
    private var content: some View {
        switch session.step {
        case .configuring:
            DatabaseSearchConfigureView(session: session)
        case .searching, .finished:
            DatabaseSearchResultsView(session: session, onOpen: open)
        }
    }

    private var footer: some View {
        DialogFooter {
            statusText
        } actions: {
            actionButtons
        }
        .padding(20)
    }

    @ViewBuilder
    private var statusText: some View {
        if session.step == .configuring, let reason = session.searchDisabledReason {
            Text(reason)
                .font(.callout)
                .foregroundStyle(.secondary)
                .lineLimit(2)
        }
    }

    @ViewBuilder
    private var actionButtons: some View {
        switch session.step {
        case .configuring:
            Button(String(localized: "Cancel"), role: .cancel) { dismiss() }
                .keyboardShortcut(.cancelAction)
            Button(String(localized: "Search")) { session.start() }
                .keyboardShortcut(.defaultAction)
                .disabled(!session.canSearch)
                .accessibilityIdentifier("database-search-start")
        case .searching:
            Button(String(localized: "Stop")) { session.stop() }
                .keyboardShortcut(.cancelAction)
                .accessibilityIdentifier("database-search-stop")
        case .finished:
            Button(String(localized: "Edit Search")) { session.editSearch() }
                .accessibilityIdentifier("database-search-edit")
            Button(String(localized: "Done"), role: .cancel) { dismiss() }
                .keyboardShortcut(.cancelAction)
            Button(String(localized: "Open")) {
                if let selected = session.selectedMatch { open(selected) }
            }
            .keyboardShortcut(.defaultAction)
            .disabled(session.selectedMatch == nil)
            .accessibilityIdentifier("database-search-open")
        }
    }

    private func open(_ result: DatabaseSearchTableResult) {
        guard result.match != nil else { return }
        onOpen(result)
    }
}
