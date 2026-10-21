//
//  DatabaseSearchConfigureView.swift
//  TablePro
//

import SwiftUI

internal struct DatabaseSearchConfigureView: View {
    @ObservedObject internal var session: DatabaseSearchSession
    @FocusState private var isTermFocused: Bool

    internal var body: some View {
        HStack(spacing: 0) {
            settings
                .padding(20)
                .frame(width: 300, alignment: .topLeading)
                .frame(maxHeight: .infinity, alignment: .top)
            Divider()
            DatabaseSearchTableListView(session: session)
                .frame(maxWidth: .infinity)
        }
        .frame(maxHeight: .infinity)
        .onAppear { isTermFocused = true }
    }

    private var settings: some View {
        VStack(alignment: .leading, spacing: 18) {
            labelled(String(localized: "Find")) {
                TextField(String(localized: "Value"), text: $session.options.term)
                    .textFieldStyle(.roundedBorder)
                    .focused($isTermFocused)
                    .onSubmit { session.start() }
                    .accessibilityLabel(String(localized: "Find"))
                    .accessibilityIdentifier("database-search-term")
            }
            labelled(String(localized: "Match")) {
                Picker(String(localized: "Match"), selection: $session.options.matchMode) {
                    ForEach(DatabaseSearchMatchMode.allCases) { mode in
                        Text(mode.displayName).tag(mode)
                    }
                }
                .labelsHidden()
                .accessibilityIdentifier("database-search-match")
                Toggle(String(localized: "Match Case"), isOn: $session.options.isCaseSensitive)
                    .toggleStyle(.checkbox)
                    .disabled(!session.caseMatching.isAdjustable)
                    .accessibilityIdentifier("database-search-case-sensitive")
                if let reason = session.caseMatching.fixedReason {
                    Text(reason)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            labelled(String(localized: "Columns")) {
                Toggle(String(localized: "Include binary columns"), isOn: $session.options.includesBinaryColumns)
                    .toggleStyle(.checkbox)
                    .accessibilityIdentifier("database-search-binary")
                Text(String(localized: "Text columns are always searched. Number, date and UUID columns are searched when the value reads as one, and are compared exactly."))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private func labelled(_ title: String, @ViewBuilder content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.subheadline.weight(.medium))
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

internal struct DatabaseSearchTableListView: View {
    @ObservedObject internal var session: DatabaseSearchSession

    internal var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider()
            list
            if session.catalogState == .loaded, !session.targets.isEmpty {
                Divider()
                Text(session.selectionSummary)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .accessibilityIdentifier("database-search-selection-summary")
            }
        }
    }

    private var toolbar: some View {
        HStack(spacing: 8) {
            NativeSearchField(
                text: $session.tableFilter,
                placeholder: String(localized: "Filter Tables"),
                controlSize: .small,
                accessibilityIdentifier: "database-search-table-filter"
            )
            Spacer(minLength: 8)
            Button(String(localized: "Select All")) { session.selectAllFiltered() }
                .controlSize(.small)
                .disabled(!session.canSelectAllFiltered)
            Button(String(localized: "Deselect All")) { session.deselectAllFiltered() }
                .controlSize(.small)
                .disabled(!session.canDeselectAllFiltered)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    @ViewBuilder
    private var list: some View {
        switch session.catalogState {
        case .idle, .loading:
            VStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text(String(localized: "Reading the tables…"))
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .failed(let message):
            UnavailableStateView {
                Label(String(localized: "Cannot Read the Tables"), systemImage: "exclamationmark.triangle")
            } description: {
                RevealedTextView(message)
            } actions: {
                Button(String(localized: "Try Again")) { Task { await session.loadTablesIfNeeded() } }
            }
        case .loaded:
            if session.targets.isEmpty {
                UnavailableStateView {
                    Label(String(localized: "No Tables"), systemImage: "tray")
                } description: {
                    Text(String(localized: "This database reports no tables to search."))
                }
            } else {
                tableList
            }
        }
    }

    private var tableList: some View {
        List {
            if session.showsSchemas {
                ForEach(session.schemaGroups) { group in
                    Section {
                        ForEach(group.targets) { target in
                            row(target, title: target.name)
                        }
                    } header: {
                        schemaToggle(group)
                    }
                }
            } else {
                ForEach(session.filteredTargets) { target in
                    row(target, title: target.name)
                }
            }
        }
        .listStyle(.inset)
        .accessibilityIdentifier("database-search-tables")
    }

    private func row(_ target: DatabaseSearchTarget, title: String) -> some View {
        Toggle(isOn: selection(for: target)) {
            Text(title)
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .toggleStyle(.checkbox)
    }

    // A mixed checkbox: on when every table of the schema is ticked, dashed when only some are.
    private func schemaToggle(_ group: DatabaseSearchSchemaGroup) -> some View {
        Toggle(sources: group.targets.map(selection(for:)), isOn: \.self) {
            Text(group.schema ?? "")
        }
        .toggleStyle(.checkbox)
    }

    private func selection(for target: DatabaseSearchTarget) -> Binding<Bool> {
        Binding(
            get: { session.isSelected(target) },
            set: { session.setSelected(target, $0) }
        )
    }
}
