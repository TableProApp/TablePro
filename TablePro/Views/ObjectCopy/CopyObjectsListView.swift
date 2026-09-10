//
//  CopyObjectsListView.swift
//  TablePro
//
//  The objects the source has, with the ones taking part ticked.
//

import SwiftUI
import TableProPluginKit

internal struct CopyObjectsListView: View {
    @Bindable internal var session: ObjectCopySession

    internal var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider()
            list
            /// Withheld until there is a catalog to count. "0 of 0 selected" under a spinner
            /// reports a state the source has not answered for yet.
            if !session.isLoadingObjects, !session.availableObjects.isEmpty {
                Divider()
                status
            }
        }
    }

    /// `NSSearchField` rather than a text field wearing a magnifying glass. It brings the recessed
    /// search shape, the clear button and the search menu, and it is the only one of the two that
    /// takes Escape: a plain field lets the key through to the sheet's Cancel, so clearing a
    /// filter threw away the target, the content choice and every tick with it.
    private var toolbar: some View {
        HStack(spacing: 8) {
            NativeSearchField(
                text: $session.searchText,
                placeholder: String(localized: "Search"),
                controlSize: .small,
                accessibilityIdentifier: "copy-objects-search"
            )
            Spacer(minLength: 8)
            /// Both act on what the search is showing, which is why they are disabled the moment
            /// there is nothing left for them to change rather than staying lit over a no-op.
            Button(String(localized: "Select All")) { session.selectAll() }
                .controlSize(.small)
                .disabled(!session.canSelectAllFiltered)
            Button(String(localized: "Deselect All")) { session.selectNone() }
                .controlSize(.small)
                .disabled(!session.canDeselectAllFiltered)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    /// What the copy will actually carry. The list shows the filter's result, so without a count
    /// of the whole selection a search hides how much is ticked outside it.
    private var status: some View {
        Text(session.selectionSummary)
            .font(.caption)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .accessibilityIdentifier("copy-objects-selection-summary")
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

    /// The tick and the filter are siblings rather than one inside the other: a button inside a
    /// `Toggle`'s label is still part of the toggle's hit area, so opening the filter would flip
    /// the object out of the copy on the way.
    private func row(_ object: ObjectCopySelection) -> some View {
        HStack(spacing: 6) {
            /// The value SwiftUI hands the setter, never an unconditional flip. A binding that
            /// inverts whatever it is written turns any write of the value it already holds into a
            /// change, so a re-render, an accessibility `setValue`, or a second delivery while the
            /// list diffs under a search keystroke silently took an object out of the copy or put
            /// one in.
            Toggle(isOn: Binding(
                get: { session.selectedObjectIds.contains(object.id) },
                set: { session.setSelected(object, $0) }
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
            /// Outside the toggle, beside the control that sets it. A `Toggle` folds its whole
            /// label into one accessibility element, so a summary placed in there is spoken as part
            /// of the checkbox and cannot be read on its own.
            scopeSummary(object)
            if session.allowsRowFilter(for: object) {
                filterButton(object)
            }
        }
    }

    /// Shown only where the filter would act. A copy switched to structure only carries no rows for
    /// a `WHERE` to narrow, and a row still advertising one would misreport what is about to happen.
    @ViewBuilder
    private func scopeSummary(_ object: ObjectCopySelection) -> some View {
        let scope = session.rowScope(for: object)
        if session.allowsRowFilter(for: object), !scope.isUnrestricted, !scope.summary.isEmpty {
            Text(scope.summary)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
                .accessibilityIdentifier("copy-objects-row-scope-\(object.qualifiedName)")
        }
    }

    /// The same editor the export tree narrows a table with, minus its column list: a copy that
    /// also writes the structure would otherwise build a table whose columns and whose `INSERT`
    /// disagree.
    private func filterButton(_ object: ObjectCopySelection) -> some View {
        /// Filled for a refused filter as well as a working one. A filter the sanitizer threw out
        /// is the one the user most needs to find again, and it is also the one holding Continue.
        let isFiltered = session.hasRowFilter(for: object)
        return Button {
            session.rowFilterObjectId = object.id
        } label: {
            Image(systemName: isFiltered
                ? "line.3.horizontal.decrease.circle.fill"
                : "line.3.horizontal.decrease.circle")
        }
        .buttonStyle(.borderless)
        .foregroundStyle(isFiltered ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(.secondary))
        .help(String(localized: "Choose which rows of this table are copied"))
        .accessibilityLabel(String(localized: "Filter rows"))
        .accessibilityIdentifier("copy-objects-row-filter-\(object.qualifiedName)")
        .popover(
            isPresented: Binding(
                get: { session.rowFilterObjectId == object.id },
                set: { if !$0, session.rowFilterObjectId == object.id { session.rowFilterObjectId = nil } }
            ),
            arrowEdge: .trailing
        ) {
            ExportRowScopeEditor(
                objectName: object.displayName,
                availableColumns: [],
                scope: Binding(
                    get: { session.rowScope(for: object) },
                    set: { session.setRowScope($0, for: object) }
                ),
                dismiss: { session.rowFilterObjectId = nil }
            )
        }
    }

    private func centred(@ViewBuilder content: () -> some View) -> some View {
        VStack(spacing: 8) { content() }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
