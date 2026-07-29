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
    @State private var jumpText = ""
    @State private var customText = ""
    @FocusState private var isJumpFocused: Bool
    @FocusState private var isCustomFocused: Bool

    private static let pageSizePresets = [5, 10, 20, 100, 500, 1_000]

    var body: some View {
        HStack(spacing: 8) {
            pageSizeMenu
            navigationCluster
        }
    }

    // MARK: - Page Size Menu

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
                .disabled(!pagination.isLastPageKnown)
            Button(String(localized: "Custom…")) {
                customText = "\(pagination.pageSize)"
                showCustomPopover = true
            }
        } label: {
            Text(pageSizeLabel)
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .controlSize(.small)
        .help(String(localized: "Rows per page"))
        .accessibilityLabel(String(localized: "Rows per page"))
        .overlay(alignment: .bottom) {
            Color.clear
                .frame(width: 0, height: 0)
                .popover(isPresented: $showCustomPopover, arrowEdge: .top) {
                    customPageSizePopover
                }
        }
    }

    private var pageSizeBinding: Binding<Int> {
        Binding(get: { pagination.pageSize }, set: { onPageSizeChange($0) })
    }

    private var pageSizeLabel: String {
        pagination.pageSize.formatted()
    }

    // MARK: - Navigation

    private var navigationCluster: some View {
        HStack(spacing: 2) {
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
                enabled: pagination.isLastPageKnown && pagination.currentPage != pagination.totalPages,
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
        Button(action: action) {
            Image(systemName: symbol)
                .imageScale(.small)
                .frame(width: 22, height: 22)
        }
        .buttonStyle(.borderless)
        .disabled(!enabled || pagination.isLoading)
        .help(helpText(label, for: shortcut))
        .accessibilityLabel(label)
    }

    private func helpText(_ label: String, for shortcut: ShortcutAction) -> String {
        AppSettingsManager.shared.keyboard.shortcutHint(label, for: shortcut)
    }

    private var pageIndicator: some View {
        Button {
            jumpText = "\(pagination.currentPage)"
            showJumpPopover = true
        } label: {
            Text(pageIndicatorText)
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(minWidth: 44)
        }
        .buttonStyle(.plain)
        .disabled(!pagination.isLastPageKnown)
        .help(String(localized: "Go to page"))
        .accessibilityLabel(pageIndicatorAccessibilityLabel)
        .popover(isPresented: $showJumpPopover, arrowEdge: .top) {
            jumpPopover
        }
    }

    private var pageIndicatorText: String {
        guard pagination.isLastPageKnown else { return "\(pagination.currentPage)" }
        return "\(pagination.currentPage) / \(pagination.totalPages)"
    }

    private var pageIndicatorAccessibilityLabel: String {
        guard pagination.isLastPageKnown else {
            return String(format: String(localized: "Page %d"), pagination.currentPage)
        }
        return String(format: String(localized: "Page %d of %d"), pagination.currentPage, pagination.totalPages)
    }

    // MARK: - Popovers

    private var jumpPopover: some View {
        submitPopover(
            caption: "Go to page",
            text: $jumpText,
            fieldWidth: 70,
            isFocused: $isJumpFocused,
            fieldAccessibilityLabel: String(localized: "Page number"),
            buttonTitle: "Go",
            action: submitJump
        )
    }

    private var customPageSizePopover: some View {
        submitPopover(
            caption: "Rows per page",
            text: $customText,
            fieldWidth: 80,
            isFocused: $isCustomFocused,
            fieldAccessibilityLabel: String(localized: "Rows per page"),
            buttonTitle: "Apply",
            action: submitCustom
        )
    }

    private func submitPopover(
        caption: LocalizedStringKey,
        text: Binding<String>,
        fieldWidth: CGFloat,
        isFocused: FocusState<Bool>.Binding,
        fieldAccessibilityLabel: String,
        buttonTitle: LocalizedStringKey,
        action: @escaping () -> Void
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(caption)
                .font(.caption)
                .foregroundStyle(.secondary)
            HStack {
                TextField("", text: text)
                    .frame(width: fieldWidth)
                    .focused(isFocused)
                    .onSubmit(action)
                    .accessibilityLabel(fieldAccessibilityLabel)
                Button(buttonTitle, action: action)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(12)
        .onAppear { isFocused.wrappedValue = true }
    }

    // MARK: - Actions

    private func submitJump() {
        if let page = Int(jumpText), page > 0, page <= pagination.totalPages {
            onGoToPage(page)
        }
        showJumpPopover = false
    }

    private func submitCustom() {
        if let size = Int(customText), size > 0 {
            onPageSizeChange(size)
        }
        showCustomPopover = false
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
