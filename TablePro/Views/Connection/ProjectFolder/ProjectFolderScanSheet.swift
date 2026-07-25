//
//  ProjectFolderScanSheet.swift
//  TablePro
//

import SwiftUI

struct ProjectFolderScanSheet: View {
    let rootURL: URL
    let onSelect: (ParsedConnectionURL) -> Void
    let onChooseAnotherFolder: () -> Void

    @State private var step: Step = .scanning
    @State private var selection: UUID?
    @Environment(\.dismiss) private var dismiss

    private enum Step {
        case scanning
        case results([ScannedConnectionCandidate])
        case empty
        case error(String)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            header
            content
            footer
        }
        .padding(20)
        .frame(width: 520, height: 440)
        .task(id: rootURL) {
            await runScan()
        }
    }

    private var projectName: String {
        rootURL.lastPathComponent
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(String(localized: "Open Project Folder"))
                .font(.headline)
            Text(String(format: String(localized: "Connections found in %@"), projectName))
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private var content: some View {
        switch step {
        case .scanning:
            centered {
                ProgressView()
                Text(String(localized: "Looking for database settings…"))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        case .results(let candidates):
            VStack(alignment: .leading, spacing: 6) {
                ProjectFolderCandidateList(
                    candidates: candidates,
                    projectRoot: rootURL,
                    selection: $selection
                )
                detailStrip
            }
        case .empty:
            centered {
                Image(systemName: "folder.badge.questionmark")
                    .font(.largeTitle)
                    .foregroundStyle(.tertiary)
                Text(String(localized: "No database settings found in this folder."))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
        case .error(let message):
            centered {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.largeTitle)
                    .foregroundStyle(.orange)
                Text(message)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
        }
    }

    private var footer: some View {
        HStack {
            Button(String(localized: "Choose Another Folder…")) {
                dismiss()
                onChooseAnotherFolder()
            }
            Spacer()
            Button(String(localized: "Cancel")) {
                dismiss()
            }
            .keyboardShortcut(.cancelAction)

            Button(String(localized: "Continue")) {
                submit()
            }
            .keyboardShortcut(.defaultAction)
            .buttonStyle(.borderedProminent)
            .disabled(selectedCandidate == nil)
        }
    }

    private var detailStrip: some View {
        Text(verbatim: selectedCandidate.map(Self.notes) ?? "")
            .font(.footnote)
            .foregroundStyle(.secondary)
            .lineLimit(2)
            .frame(maxWidth: .infinity, minHeight: 30, alignment: .topLeading)
    }

    private static func notes(for candidate: ScannedConnectionCandidate) -> String {
        var notes = candidate.warnings
        if candidate.placeholderSuspected {
            notes.insert(String(localized: "Looks like a placeholder value"), at: 0)
        }
        return notes.joined(separator: " · ")
    }

    private var selectedCandidate: ScannedConnectionCandidate? {
        guard case .results(let candidates) = step, let selection else {
            return nil
        }
        return candidates.first { $0.id == selection }
    }

    private func centered<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        VStack(spacing: 10) {
            Spacer()
            content()
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }

    private func submit() {
        guard let candidate = selectedCandidate else {
            return
        }
        dismiss()
        onSelect(candidate.parsedURL)
    }

    private func runScan() async {
        step = .scanning
        selection = nil
        let url = rootURL
        let result = await Task.detached(priority: .userInitiated) {
            ProjectFolderScanner.scan(rootURL: url)
        }.value
        switch result {
        case .success(let scan):
            step = scan.candidates.isEmpty ? .empty : .results(scan.candidates)
            selection = scan.candidates.first?.id
        case .failure(let error):
            step = .error(error.localizedDescription)
        }
    }
}
