//
//  PaginationControlsView.swift
//  TablePro
//

import SwiftUI

struct PaginationControlsView: View {
    let pagination: PaginationState
    let loadedRowCount: Int
    let onFirst: () -> Void
    let onPrevious: () -> Void
    let onNext: () -> Void
    let onLast: () -> Void
    let onPageSizeChange: (Int) -> Void
    let onShowAll: () -> Void
    let onGoToPage: (Int) -> Void

    @State private var showJumpPopover = false
    @State private var showCustomPopover = false
    @State private var jumpPage: Int?
    @State private var customPageSize: Int?
    @FocusState private var isJumpFocused: Bool
    @FocusState private var isCustomFocused: Bool

    private static let pageSizePresets = [5, 10, 20, 100, 500, 1_000]

    /// Anything past this is a mistake rather than an intent, and it used to be unbounded: pasting
    /// `9223372036854775807` set the page size to `Int.max` and the next status-bar render trapped.
    static let maximumPageSize = 1_000_000

    var body: some View {
        HStack(spacing: 6) {
            pageSizeMenu
            navigationCluster
        }
    }

    // MARK: - Page Size

    /// A bordered pull-down rather than a borderless one. Measured on macOS 27, a borderless
    /// `NSPopUpButton` reports a 16pt fitting height and ignores `controlSize` at every size, so it
    /// sat visibly shorter than the 20pt bordered controls beside it.
    private var pageSizeMenu: some View {
        Menu {
            Picker(String(localized: "Rows per page"), selection: pageSizeBinding) {
                ForEach(Self.pageSizePresets, id: \.self) { size in
                    Text(size.formatted()).tag(size)
                }
            }
            .pickerStyle(.inline)

            Divider()

            Button(String(localized: "All rows…")) { onShowAll() }
                .disabled(!pagination.hasExactRowCount)
            Button(String(localized: "Custom…")) {
                customPageSize = pagination.pageSize
                showCustomPopover = true
            }
        } label: {
            Text(pagination.pageSize.formatted())
                .monospacedDigit()
        }
        .menuStyle(.button)
        .fixedSize()
        .controlSize(.small)
        .help(String(localized: "Rows per page"))
        .accessibilityLabel(String(localized: "Rows per page"))
        .accessibilityValue(pagination.pageSize.formatted())
        .accessibilityIdentifier("pagination-page-size")
        .popover(isPresented: $showCustomPopover, arrowEdge: .top) {
            customPageSizePopover
        }
    }

    private var pageSizeBinding: Binding<Int> {
        Binding(get: { pagination.pageSize }, set: { onPageSizeChange($0) })
    }

    // MARK: - Navigation

    private var navigationCluster: some View {
        HStack(spacing: 0) {
            navButton(
                "chevron.backward.to.line",
                label: String(localized: "First page"),
                enabled: pagination.hasPreviousPage,
                action: onFirst,
                shortcut: .firstPage
            )
            navButton(
                "chevron.backward",
                label: String(localized: "Previous page"),
                enabled: pagination.hasPreviousPage,
                action: onPrevious,
                shortcut: .previousPage
            )

            pageIndicator

            if pagination.isLoading {
                ProgressView()
                    .controlSize(.small)
                    .accessibilityLabel(String(localized: "Loading page"))
            }

            navButton(
                "chevron.forward",
                label: String(localized: "Next page"),
                enabled: pagination.canGoToNextPage(loadedRowCount: loadedRowCount),
                action: onNext,
                shortcut: .nextPage
            )
            navButton(
                "chevron.forward.to.line",
                label: String(localized: "Last page"),
                enabled: pagination.hasExactRowCount && pagination.currentPage != pagination.totalPages,
                action: onLast,
                shortcut: .lastPage
            )
        }
    }

    private func navButton(
        _ symbol: String,
        label: String,
        enabled: Bool,
        action: @escaping () -> Void,
        shortcut: ShortcutAction
    ) -> some View {
        Button(label, systemImage: symbol, action: action)
            .labelStyle(.iconOnly)
            .imageScale(.small)
            .frame(width: 20, height: 20)
            .buttonStyle(.borderless)
            .disabled(!enabled || pagination.isLoading)
            .help(helpText(label, for: shortcut))
    }

    private func helpText(_ label: String, for shortcut: ShortcutAction) -> String {
        AppSettingsManager.shared.keyboard.shortcutHint(label, for: shortcut)
    }

    private var pageIndicator: some View {
        Button {
            jumpPage = pagination.currentPage
            showJumpPopover = true
        } label: {
            pageIndicatorText
                .font(.caption)
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .frame(minWidth: 44)
        }
        .buttonStyle(.plain)
        .disabled(!pagination.hasRowCountTotal)
        .help(String(localized: "Go to page"))
        .accessibilityLabel(String(localized: "Page"))
        .accessibilityValue(pageIndicatorAccessibilityValue)
        .accessibilityIdentifier("pagination-page-indicator")
        .popover(isPresented: $showJumpPopover, arrowEdge: .top) {
            jumpPopover
        }
    }

    /// The total is marked when it came from a driver estimate, so a page count the user cannot
    /// trust never looks like one they can.
    @ViewBuilder
    private var pageIndicatorText: some View {
        if pagination.hasExactRowCount {
            Text("\(pagination.currentPage) / \(pagination.totalPages)")
        } else if pagination.hasRowCountTotal {
            Text("\(pagination.currentPage) / ~\(pagination.totalPages)")
        } else {
            Text("\(pagination.currentPage)")
        }
    }

    private var pageIndicatorAccessibilityValue: String {
        guard pagination.hasRowCountTotal else {
            return String(format: String(localized: "Page %d"), pagination.currentPage)
        }
        return String(format: String(localized: "Page %d of %d"), pagination.currentPage, pagination.totalPages)
    }

    // MARK: - Popovers

    private var jumpPopover: some View {
        NumberEntryPopover(
            caption: String(localized: "Go to page"),
            value: $jumpPage,
            minimum: 1,
            /// An estimated total is not a ceiling. Clamping to it here would put back the wall that
            /// `PaginationState.goToPage` was opened up to remove.
            maximum: pagination.hasExactRowCount ? pagination.totalPages : nil,
            fieldWidth: 80,
            isFocused: $isJumpFocused,
            fieldAccessibilityLabel: String(localized: "Page number"),
            buttonTitle: String(localized: "Go"),
            onSubmit: { page in
                onGoToPage(page)
                showJumpPopover = false
            }
        )
    }

    private var customPageSizePopover: some View {
        NumberEntryPopover(
            caption: String(localized: "Rows per page"),
            value: $customPageSize,
            minimum: 1,
            maximum: Self.maximumPageSize,
            fieldWidth: 90,
            isFocused: $isCustomFocused,
            fieldAccessibilityLabel: String(localized: "Rows per page"),
            buttonTitle: String(localized: "Apply"),
            onSubmit: { size in
                onPageSizeChange(size)
                showCustomPopover = false
            }
        )
    }
}

#Preview {
    VStack(spacing: 20) {
        PaginationControlsView(
            pagination: PaginationState(totalRowCount: 5_000, pageSize: 1_000, currentPage: 3, currentOffset: 2_000),
            loadedRowCount: 1_000,
            onFirst: {}, onPrevious: {}, onNext: {}, onLast: {},
            onPageSizeChange: { _ in }, onShowAll: {}, onGoToPage: { _ in }
        )

        PaginationControlsView(
            pagination: PaginationState(totalRowCount: nil, pageSize: 1_000, currentPage: 2, currentOffset: 1_000),
            loadedRowCount: 1_000,
            onFirst: {}, onPrevious: {}, onNext: {}, onLast: {},
            onPageSizeChange: { _ in }, onShowAll: {}, onGoToPage: { _ in }
        )
    }
    .padding()
}
