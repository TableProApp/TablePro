//
//  VersionHistoryDetailHeader.swift
//  TablePro
//

import SwiftUI

internal struct VersionHistoryDetailHeader: View {
    @ObservedObject var viewModel: VersionHistoryViewModel

    var body: some View {
        HStack(spacing: 12) {
            if let entry = viewModel.selectedEntry {
                VStack(alignment: .leading, spacing: 2) {
                    Text(VersionHistoryFormatting.title(for: entry))
                        .font(.headline)
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .textSelection(.enabled)
                    let subtitle = VersionHistoryFormatting.subtitle(for: entry)
                    if !subtitle.isEmpty {
                        Text(subtitle)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .textSelection(.enabled)
                    }
                }
            }
            Spacer(minLength: 8)
            Picker(String(localized: "Show"), selection: $viewModel.displayMode) {
                Text("Changes").tag(VersionHistoryViewModel.DisplayMode.changes)
                Text("Content").tag(VersionHistoryViewModel.DisplayMode.content)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
            .accessibilityIdentifier("version-history-display-mode")
            if viewModel.displayMode == .changes {
                Picker(String(localized: "Layout"), selection: $viewModel.diffLayout) {
                    Text("Split").tag(TextDiffLayout.split)
                    Text("Unified").tag(TextDiffLayout.unified)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
            }
            Button(String(localized: "Restore This Version"), action: restoreSelection)
                .disabled(!viewModel.canRestoreSelection)
                .help(String(localized: "Replace the current text with this version"))
                .accessibilityIdentifier("version-history-restore")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Color(nsColor: .controlBackgroundColor))
    }

    private func restoreSelection() {
        guard let entry = viewModel.selectedEntry else { return }
        Task { await viewModel.restore(entry) }
    }
}
