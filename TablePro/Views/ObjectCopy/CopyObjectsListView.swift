//
//  CopyObjectsListView.swift
//  TablePro
//
//  The objects the source has, with the ones taking part ticked.
//

import SwiftUI

internal struct CopyObjectsListView: View {
    @Bindable internal var session: ObjectCopySession

    internal var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider()
            list
        }
    }

    private var toolbar: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
            TextField(String(localized: "Search"), text: $session.searchText)
                .textFieldStyle(.plain)
                .accessibilityIdentifier("copy-objects-search")
            Spacer(minLength: 8)
            Button(String(localized: "All")) { session.selectAll() }
                .controlSize(.small)
            Button(String(localized: "None")) { session.selectNone() }
                .controlSize(.small)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    @ViewBuilder
    private var list: some View {
        if session.isLoadingObjects {
            centred {
                ProgressView().controlSize(.small)
                Text("Reading the source…")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        } else if let message = session.catalogError {
            ContentUnavailableView {
                Label("Cannot Read the Source", systemImage: "exclamationmark.triangle")
            } description: {
                Text(message)
            } actions: {
                Button("Try Again") { Task { await session.loadObjects() } }
            }
        } else if session.filteredObjects.isEmpty {
            ContentUnavailableView {
                Label("Nothing to Copy", systemImage: "tray")
            } description: {
                Text("This database reports no objects.")
            }
        } else {
            List(session.filteredObjects) { object in
                row(object)
            }
            .listStyle(.inset)
            .accessibilityIdentifier("copy-objects-list")
        }
    }

    private func row(_ object: ObjectCopySelection) -> some View {
        Toggle(isOn: Binding(
            get: { session.selectedObjectIds.contains(object.id) },
            set: { _ in session.toggle(object) }
        )) {
            HStack(spacing: 6) {
                /// The signature or the owning table, not just the name: two overloads and two
                /// same-named triggers are two rows and have to read as two.
                Text(object.displayName)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 8)
                Text(object.kind.displayName)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .toggleStyle(.checkbox)
    }

    private func centred(@ViewBuilder content: () -> some View) -> some View {
        VStack(spacing: 8) { content() }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
