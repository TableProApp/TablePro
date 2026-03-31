//
//  PaginationControlsView.swift
//  TablePro
//
//  Pagination controls for navigating large datasets (TablePlus-style)
//

import SwiftUI

/// Pagination controls displayed in the status bar (TablePlus design)
struct PaginationControlsView: View {
    let pagination: PaginationState
    let onFirst: () -> Void
    let onPrevious: () -> Void
    let onNext: () -> Void
    let onLast: () -> Void
    let onLimitChange: (Int) -> Void
    let onOffsetChange: (Int) -> Void
    let onGo: () -> Void

    @State private var limitText: String = ""
    @State private var offsetText: String = ""
    @State private var showSettings = false
    @FocusState private var isLimitFocused: Bool
    @FocusState private var isOffsetFocused: Bool

    var body: some View {
        HStack(spacing: 8) {
            // Navigation buttons
            navigationButtons

            // Settings button (gear icon) - opens popover
            Button(action: { showSettings.toggle() }) {
                Image(systemName: "slider.horizontal.3")
                    .font(.system(size: 12))
            }
            .buttonStyle(.borderless)
            .help("Pagination Settings")
            .popover(isPresented: $showSettings, arrowEdge: .top) {
                settingsPopover
            }
        }
        .onAppear {
            limitText = "\(pagination.pageSize)"
            offsetText = "\(pagination.currentOffset)"
        }
        .onChange(of: pagination.pageSize) { _, newValue in
            limitText = "\(newValue)"
        }
        .onChange(of: pagination.currentOffset) { _, newValue in
            offsetText = "\(newValue)"
        }
    }

    // MARK: - Navigation Buttons

    private var navigationButtons: some View {
        HStack(spacing: 4) {
            // Previous page button
            Button(action: onPrevious) {
                Image(systemName: "chevron.left")
                    .font(.system(size: 11))
            }
            .buttonStyle(.borderless)
            .disabled(!pagination.hasPreviousPage || pagination.isLoading)
            .help("Previous Page (⌘[)")
            .keyboardShortcut("[", modifiers: .command)

            // Page indicator: "1 of 25"
            Text("\(pagination.currentPage) of \(pagination.totalPages)")
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(minWidth: 60)

            if pagination.isLoading {
                ProgressView()
                    .controlSize(.small)
            }

            // Next page button
            Button(action: onNext) {
                Image(systemName: "chevron.right")
                    .font(.system(size: 11))
            }
            .buttonStyle(.borderless)
            .disabled(!pagination.hasNextPage || pagination.isLoading)
            .help("Next Page (⌘])")
            .keyboardShortcut("]", modifiers: .command)
        }
    }

    // MARK: - Settings Popover

    private var settingsPopover: some View {
        VStack(alignment: .leading, spacing: 12) {
            // Limit field
            VStack(alignment: .leading, spacing: 4) {
                Text("Limit")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                TextField("Limit", text: $limitText)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 120)
                    .focused($isLimitFocused)
                    .onSubmit {
                        applyLimitChange()
                    }
            }

            // Offset field
            VStack(alignment: .leading, spacing: 4) {
                Text("Offset")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                TextField("Offset", text: $offsetText)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 120)
                    .focused($isOffsetFocused)
                    .onSubmit {
                        applyOffsetChange()
                    }
            }

            // Go button
            Button(action: {
                applyLimitChange()
                applyOffsetChange()
                showSettings = false
            }) {
                Text("Go")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
        }
        .padding(12)
        .frame(width: 160)
    }

    // MARK: - Helpers

    private func applyLimitChange() {
        if let limit = Int(limitText), limit > 0 {
            onLimitChange(limit)
        } else {
            limitText = "\(pagination.pageSize)"
        }
    }

    private func applyOffsetChange() {
        if let offset = Int(offsetText), offset >= 0 {
            onOffsetChange(offset)
        } else {
            offsetText = "\(pagination.currentOffset)"
        }
    }
}

#Preview {
    VStack(spacing: 20) {
        // Preview with multiple pages
        PaginationControlsView(
            pagination: PaginationState(
                totalRowCount: 5_000,
                pageSize: 200,
                currentPage: 3,
                currentOffset: 400,
                isLoading: false
            ),
            onFirst: {},
            onPrevious: {},
            onNext: {},
            onLast: {},
            onLimitChange: { _ in },
            onOffsetChange: { _ in },
            onGo: {}
        )

        // Preview on first page
        PaginationControlsView(
            pagination: PaginationState(
                totalRowCount: 1_000,
                pageSize: 200,
                currentPage: 1,
                currentOffset: 0,
                isLoading: false
            ),
            onFirst: {},
            onPrevious: {},
            onNext: {},
            onLast: {},
            onLimitChange: { _ in },
            onOffsetChange: { _ in },
            onGo: {}
        )

        // Preview loading state
        PaginationControlsView(
            pagination: PaginationState(
                totalRowCount: 5_000,
                pageSize: 200,
                currentPage: 2,
                currentOffset: 200,
                isLoading: true
            ),
            onFirst: {},
            onPrevious: {},
            onNext: {},
            onLast: {},
            onLimitChange: { _ in },
            onOffsetChange: { _ in },
            onGo: {}
        )
    }
    .padding()
}
