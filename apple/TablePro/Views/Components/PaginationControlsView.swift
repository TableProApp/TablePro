import SwiftUI

struct PaginationControlsView: View {
    @ObservedObject private var keyboard = AppSettingsManager.shared.keyboardSlice
    let pagination: PaginationState
    let loadedRowCount: Int
    // Not displayed: a change discards a half-typed page number so it cannot be submitted against the next tab.
    let tabId: UUID?
    var showsPageNavigation = true
    // The Query menu carries all four page commands, so First and Last go first when the bar runs out of room.
    var showsEdgePageButtons = true
    // Rows-per-page has no menu-bar home, so a narrow bar folds it into the page menu rather than dropping it.
    var pageSizeIsInline = true
    var maximumPageSize: Int?
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

    // Bounded: pasting `Int.max` as the page size trapped the next status bar render.
    static let maximumPageSize = 1_000_000

    static func pageSizePresets(upTo maximum: Int?) -> [Int] {
        guard let maximum else { return pageSizePresets }
        return pageSizePresets.filter { $0 <= maximum }
    }

    private var customPageSizeLimit: Int {
        min(maximumPageSize ?? Self.maximumPageSize, Self.maximumPageSize)
    }

    // An engine that cannot seek has no page indicator to fold rows-per-page into.
    private var showsInlinePageSize: Bool {
        pageSizeIsInline || !showsPageNavigation
    }

    var body: some View {
        HStack(spacing: 6) {
            if showsInlinePageSize {
                pageSizeMenu
            }
            if showsPageNavigation {
                navigationCluster
            }
        }
        .onChange(of: tabId) { _ in
            showJumpPopover = false
            showCustomPopover = false
            jumpPage = nil
            customPageSize = nil
        }
    }

    // Bordered: a borderless `NSPopUpButton` ignores `controlSize` and sat shorter than the controls beside it.
    private var pageSizeMenu: some View {
        Menu {
            pageSizeMenuItems
        } label: {
            Text(pagination.pageSize.formatted())
                .monospacedDigit()
                .accessibilityLabel(String(localized: "Rows per page"))
        }
        .menuStyle(.button)
        .fixedSize()
        .controlSize(.small)
        .disabled(pagination.isLoading)
        .help(String(localized: "Rows per page"))
        .accessibilityValue(pagination.pageSize.formatted())
        .accessibilityIdentifier("pagination-page-size")
        .popover(isPresented: $showCustomPopover, arrowEdge: .top) {
            customPageSizePopover
        }
    }

    // Shared, so rows-per-page offers the same choices whichever control carries it.
    @ViewBuilder
    private var pageSizeMenuItems: some View {
        Picker(String(localized: "Rows per page"), selection: pageSizeBinding) {
            ForEach(Self.pageSizePresets(upTo: maximumPageSize), id: \.self) { size in
                Text(size.formatted()).tag(size)
            }
        }
        .pickerStyle(.inline)

        Divider()

        if showsPageNavigation {
            Button(String(localized: "All rows…")) { onShowAll() }
                .disabled(!pagination.hasExactRowCount)
        }
        Button(String(localized: "Custom…")) {
            customPageSize = pagination.pageSize
            showCustomPopover = true
        }
    }

    private var pageSizeBinding: Binding<Int> {
        Binding(get: { pagination.pageSize }, set: { onPageSizeChange($0) })
    }

    // No progress indicator here: it would push the nav buttons sideways on every page load.
    private var navigationCluster: some View {
        HStack(spacing: 0) {
            if showsEdgePageButtons {
                navButton(
                    "chevron.backward.to.line",
                    label: String(localized: "First page"),
                    enabled: pagination.hasPreviousPage,
                    action: onFirst,
                    shortcut: .firstPage
                )
            }
            navButton(
                "chevron.backward",
                label: String(localized: "Previous page"),
                enabled: pagination.hasPreviousPage,
                action: onPrevious,
                shortcut: .previousPage
            )

            pageIndicator

            navButton(
                "chevron.forward",
                label: String(localized: "Next page"),
                enabled: pagination.canGoToNextPage(loadedRowCount: loadedRowCount),
                action: onNext,
                shortcut: .nextPage
            )
            if showsEdgePageButtons {
                navButton(
                    "chevron.forward.to.line",
                    label: String(localized: "Last page"),
                    enabled: pagination.hasExactRowCount && pagination.currentPage != pagination.totalPages,
                    action: onLast,
                    shortcut: .lastPage
                )
            }
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
        keyboard.value.shortcutHint(label, for: shortcut)
    }

    // A menu once rows-per-page has no control of its own, so it stays reachable on a narrow bar.
    @ViewBuilder
    private var pageIndicator: some View {
        if showsInlinePageSize {
            Button {
                jumpPage = pagination.currentPage
                showJumpPopover = true
            } label: {
                pageIndicatorLabel
            }
            .buttonStyle(.plain)
            .disabled(!pagination.hasRowCountTotal || pagination.isLoading)
            .help(String(localized: "Go to page"))
            .pageIndicatorAccessibility(value: pageIndicatorAccessibilityValue)
            .popover(isPresented: $showJumpPopover, arrowEdge: .top) {
                jumpPopover
            }
        } else {
            Menu {
                // The catalog's existing spelling: a new string would fall back to English where this menu is the only route.
                Button(String(localized: "Go to page")) {
                    jumpPage = pagination.currentPage
                    showJumpPopover = true
                }
                .disabled(!pagination.hasRowCountTotal)

                Divider()

                pageSizeMenuItems
            } label: {
                pageIndicatorLabel
            }
            .menuStyle(.button)
            .buttonStyle(.borderless)
            .disabled(pagination.isLoading)
            .help(String(localized: "Go to page"))
            .pageIndicatorAccessibility(value: pageIndicatorAccessibilityValue)
            .popover(isPresented: $showJumpPopover, arrowEdge: .top) {
                jumpPopover
            }
            .popover(isPresented: $showCustomPopover, arrowEdge: .top) {
                customPageSizePopover
            }
        }
    }

    private var pageIndicatorLabel: some View {
        pageIndicatorText
            .font(.caption)
            .monospacedDigit()
            .foregroundStyle(.secondary)
            .frame(minWidth: 44)
    }

    // An estimated total is marked, so a page count the user cannot trust never looks exact.
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

    private var jumpPopover: some View {
        NumberEntryPopover(
            caption: String(localized: "Go to page"),
            value: $jumpPage,
            minimum: 1,
            // An estimated total is not a ceiling for `PaginationState.goToPage`.
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
            maximum: customPageSizeLimit,
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
            tabId: nil,
            onFirst: {}, onPrevious: {}, onNext: {}, onLast: {},
            onPageSizeChange: { _ in }, onShowAll: {}, onGoToPage: { _ in }
        )

        PaginationControlsView(
            pagination: PaginationState(totalRowCount: nil, pageSize: 1_000, currentPage: 2, currentOffset: 1_000),
            loadedRowCount: 1_000,
            tabId: nil,
            onFirst: {}, onPrevious: {}, onNext: {}, onLast: {},
            onPageSizeChange: { _ in }, onShowAll: {}, onGoToPage: { _ in }
        )
    }
    .padding()
}

private extension View {
    // XCUITest keys on the identifier, and the control is a button or a menu depending on the room.
    func pageIndicatorAccessibility(value: String) -> some View {
        accessibilityLabel(String(localized: "Page"))
            .accessibilityValue(value)
            .accessibilityIdentifier("pagination-page-indicator")
    }
}
