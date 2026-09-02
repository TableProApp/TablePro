//
//  ColumnJumpPanelView.swift
//  TablePro
//

import AppKit
import SwiftUI

/// Jump to Column: the grid's answer to Open Quickly, over the columns of the result on screen.
///
/// It lives in the same floating panel as Open Quickly and draws with the same chrome, so the two
/// read as one family of chooser: a search field that keeps focus, a ranked list under it, and a
/// footer that says what Return and Escape will do.
struct ColumnJumpPanelView: View {
    @State private var viewModel: ColumnJumpViewModel
    private let onCommit: (GridColumnEntry) -> Void

    init(
        entries: [GridColumnEntry],
        initialQuery: String = "",
        cursorColumnIndex: Int? = nil,
        onCommit: @escaping (GridColumnEntry) -> Void
    ) {
        _viewModel = State(wrappedValue: ColumnJumpViewModel(
            entries: entries,
            initialQuery: initialQuery,
            cursorColumnIndex: cursorColumnIndex
        ))
        self.onCommit = onCommit
    }

    var body: some View {
        ColumnJumpPanelContent(viewModel: viewModel, onCommit: onCommit)
    }
}

struct ColumnJumpPanelContent: View {
    @Environment(\.colorSchemeContrast) private var colorSchemeContrast

    @Bindable var viewModel: ColumnJumpViewModel
    let onCommit: (GridColumnEntry) -> Void

    @State private var keyMonitor: Any?

    var body: some View {
        QuickSwitcherGlassGroup {
            VStack(spacing: 0) {
                inputRow

                Divider().opacity(dividerOpacity)

                results

                Divider().opacity(dividerOpacity)

                footer
            }
            .frame(width: QuickSwitcherMetrics.width)
            .quickSwitcherSurface(cornerRadius: QuickSwitcherMetrics.cornerRadius)
        }
        .onAppear { installKeyMonitor() }
        .onDisappear { removeKeyMonitor() }
    }

    // MARK: - State

    /// The field editor owns the first Escape and branches on the raw string, so a query of
    /// nothing but spaces still has something to clear. See `QuickSwitcherPanelContent`.
    private var escapeDismissesPanel: Bool {
        viewModel.searchText.isEmpty
    }

    private var dividerOpacity: Double {
        colorSchemeContrast == .increased ? 1 : 0.6
    }

    // MARK: - Input

    private var inputRow: some View {
        HStack(spacing: 10) {
            Image(systemName: "rectangle.split.3x1")
                .font(.title2)
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)

            QuickSwitcherSearchField(
                text: $viewModel.searchText,
                placeholder: String(localized: "Jump to column…"),
                onMoveUp: { viewModel.moveSelection(by: -1) },
                onMoveDown: { viewModel.moveSelection(by: 1) },
                onSubmit: { commitSelection() },
                accessibilityIdentifier: "column-jump-search-field"
            )
        }
        .padding(.horizontal, 18)
        .frame(height: QuickSwitcherMetrics.inputRowHeight)
    }

    // MARK: - Results

    @ViewBuilder
    private var results: some View {
        if viewModel.matches.isEmpty {
            noMatchesRow
        } else {
            resultsList
        }
    }

    private var resultsList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(viewModel.matches) { match in
                        columnRow(match)
                    }
                }
                .padding(.vertical, QuickSwitcherMetrics.listVerticalPadding)
            }
            .frame(height: listHeight)
            .onAppear {
                if let id = viewModel.selectedId {
                    proxy.scrollTo(id)
                }
            }
            .onChange(of: viewModel.selectedId) { _, newValue in
                if let id = newValue {
                    proxy.scrollTo(id)
                }
            }
        }
    }

    private var listHeight: CGFloat {
        viewModel.listHeight(
            rowHeight: QuickSwitcherMetrics.rowHeight,
            maxVisibleRows: QuickSwitcherMetrics.maxVisibleRows
        ) + QuickSwitcherMetrics.listVerticalPadding * 2
    }

    private var noMatchesRow: some View {
        Text(String(format: String(localized: "No columns match “%@”"), viewModel.searchText))
            .font(.body)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 24)
            .frame(height: QuickSwitcherMetrics.rowHeight + QuickSwitcherMetrics.listVerticalPadding * 2)
    }

    private func columnRow(_ match: ColumnJumpViewModel.Match) -> some View {
        let entry = match.entry
        let isSelected = match.id == viewModel.selectedId
        let secondaryColor = isSelected ? Color.emphasizedSelectionLabel.opacity(0.85) : Color.secondary

        return HStack(spacing: 12) {
            iconView(isSelected: isSelected)

            Text(QuickSwitcherRowChrome.highlightedName(entry.name, matchedIndices: match.matchedIndices))
                .font(.body)
                .foregroundStyle(isSelected ? Color.emphasizedSelectionLabel : Color.primary)
                .lineLimit(1)
                .truncationMode(.middle)

            Spacer(minLength: 8)

            if let typeName = entry.typeName {
                Text(typeName)
                    .font(.system(.callout, design: .monospaced))
                    .foregroundStyle(secondaryColor)
                    .lineLimit(1)
            }

            if entry.isHidden {
                Text(String(localized: "Hidden"))
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(secondaryColor)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1)
                    .background(Capsule().fill(Color(nsColor: .quaternarySystemFill)))
            } else if let position = entry.position {
                Text(positionLabel(position))
                    .font(.callout)
                    .foregroundStyle(secondaryColor)
                    .monospacedDigit()
            }

            if isSelected {
                Text(commitHint(for: entry))
                    .font(.caption)
                    .foregroundStyle(secondaryColor)
            }
        }
        .padding(.horizontal, 18)
        .frame(height: QuickSwitcherMetrics.rowHeight)
        .background {
            if isSelected {
                RoundedRectangle(cornerRadius: QuickSwitcherMetrics.rowCornerRadius, style: .continuous)
                    .fill(Color(nsColor: .selectedContentBackgroundColor))
                    .padding(.horizontal, QuickSwitcherMetrics.rowInset)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture {
            viewModel.selectedId = match.id
            guard NSApp.currentEvent?.clickCount == 2 else { return }
            onCommit(entry)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Text(entry.name))
        .accessibilityValue(Text(accessibilityValue(for: entry)))
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
        .accessibilityAction { onCommit(entry) }
        .id(match.id)
    }

    private func iconView(isSelected: Bool) -> some View {
        Image(systemName: "rectangle.split.3x1")
            .font(.system(size: 14, weight: .medium))
            .foregroundStyle(isSelected ? Color.emphasizedSelectionLabel : Color.secondary)
            .frame(width: QuickSwitcherMetrics.iconContainerSize, height: QuickSwitcherMetrics.iconContainerSize)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(
                        isSelected
                            ? Color.emphasizedSelectionLabel.opacity(0.2)
                            : Color(nsColor: .quaternarySystemFill)
                    )
            )
            .accessibilityHidden(true)
    }

    private func positionLabel(_ position: Int) -> String {
        String(format: String(localized: "%d of %d"), position, viewModel.presentedColumnCount)
    }

    private func commitHint(for entry: GridColumnEntry) -> String {
        entry.isHidden ? String(localized: "Show and Jump") : String(localized: "Jump")
    }

    private func accessibilityValue(for entry: GridColumnEntry) -> String {
        var parts: [String] = []
        if let typeName = entry.typeName {
            parts.append(typeName)
        }
        if entry.isHidden {
            parts.append(String(localized: "Hidden"))
        } else if let position = entry.position {
            parts.append(positionLabel(position))
        }
        return parts.joined(separator: ", ")
    }

    // MARK: - Footer

    private var footer: some View {
        HStack(spacing: 14) {
            QuickSwitcherKeyHint(symbol: "\u{21A9}", label: String(localized: "Jump"))

            Spacer(minLength: 0)

            QuickSwitcherKeyHint(
                symbol: "\u{238B}",
                label: escapeDismissesPanel ? String(localized: "Close") : String(localized: "Clear")
            )
        }
        .padding(.horizontal, 16)
        .frame(height: QuickSwitcherMetrics.footerHeight)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(escapeHintLabel))
    }

    private var escapeHintLabel: String {
        escapeDismissesPanel
            ? String(localized: "Escape closes Jump to Column")
            : String(localized: "Escape clears the search text")
    }

    // MARK: - Keyboard

    private func installKeyMonitor() {
        guard keyMonitor == nil else { return }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            guard event.window is QuickSwitcherPanel else { return event }
            let command = QuickSwitcherKeyCommand.resolve(
                characters: event.charactersIgnoringModifiers ?? "",
                modifiers: event.modifierFlags,
                scopeCount: 0
            )
            guard let command else { return event }

            switch command {
            case let .moveSelection(offset):
                viewModel.moveSelection(by: offset)
            case .selectScope:
                return event
            case .commit:
                commitSelection()
            }
            return nil
        }
    }

    private func removeKeyMonitor() {
        if let keyMonitor {
            NSEvent.removeMonitor(keyMonitor)
        }
        keyMonitor = nil
    }

    private func commitSelection() {
        guard let entry = viewModel.selectedEntry else { return }
        onCommit(entry)
    }
}

#Preview("Wide result") {
    let entries = (1...40).map { index in
        GridColumnEntry(
            name: "column_\(index)",
            dataIndex: index - 1,
            typeName: index.isMultiple(of: 3) ? "INTEGER" : "VARCHAR(255)",
            position: index,
            isHidden: false
        )
    } + [GridColumnEntry(name: "notes", dataIndex: nil, typeName: nil, position: nil, isHidden: true)]
    let viewModel = ColumnJumpViewModel(entries: entries, initialQuery: "col")
    return ColumnJumpPanelContent(viewModel: viewModel) { _ in }
        .padding(40)
        .background(Color.gray.opacity(0.4))
}
