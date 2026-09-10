//
//  FindBarView.swift
//  TablePro
//

import SwiftUI

struct FindBarView: View {
    let coordinator: MainContentCoordinator
    let findState: TabFindState
    /// Changes whenever the rows under the bar are replaced: a page change, a refresh, a re-run, a
    /// sort, or a value filter. The match list describes display positions, so it is stale the
    /// moment any of those move and has to be recomputed rather than reused.
    let rowsRevision: Int
    let onSearchAllRows: () -> Void

    @State private var term: String = ""

    var body: some View {
        HStack(spacing: 8) {
            NativeSearchField(
                text: $term,
                placeholder: String(localized: "Find in loaded rows"),
                controlSize: .regular,
                onSubmit: { coordinator.findCoordinator.stepForward() },
                focusOnAppear: true,
                accessibilityIdentifier: "find-in-results-field"
            )
            .frame(maxWidth: 320)
            .onChange(of: term) { _, newValue in
                coordinator.findCoordinator.setTerm(newValue)
            }

            Text(counterText)
                .font(.callout)
                .foregroundStyle(.secondary)
                .monospacedDigit()
                .accessibilityLabel(counterText)

            HStack(spacing: 2) {
                Button(action: { coordinator.findCoordinator.stepBackward() }) {
                    Image(systemName: "chevron.left")
                }
                .help(String(localized: "Previous match"))
                .accessibilityLabel(String(localized: "Previous match"))

                Button(action: { coordinator.findCoordinator.stepForward() }) {
                    Image(systemName: "chevron.right")
                }
                .help(String(localized: "Next match"))
                .accessibilityLabel(String(localized: "Next match"))
            }
            .buttonStyle(.borderless)
            .disabled(findState.matches.isEmpty)

            if showsEscalation {
                Button(String(localized: "Search All Rows"), action: onSearchAllRows)
                    .buttonStyle(.borderless)
            }

            Spacer()

            Button(String(localized: "Done")) {
                coordinator.findCoordinator.dismiss()
            }
            .buttonStyle(.borderless)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .onAppear { term = findState.term }
        .onChange(of: rowsRevision) { _, _ in
            coordinator.findCoordinator.runSearch()
        }
    }

    private var counterText: String {
        guard !findState.term.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return "" }
        return FindCounterText.text(
            matchCount: findState.matches.count,
            currentIndex: findState.currentMatchIndex,
            scope: findState.scope
        )
    }

    /// Escalating rewrites the whole filter set with an OR search, because `filterLogicMode` is one
    /// mode for every row. Offering it on top of filters the user already applied would either
    /// discard them or loosen them, so the button only appears when there are none.
    private var showsEscalation: Bool {
        guard findState.matches.isEmpty, findState.canEscalateToAllRows else { return false }
        return coordinator.selectedTabFilterState.filters.isEmpty
    }
}
