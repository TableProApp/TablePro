//
//  ProjectFolderCandidateList.swift
//  TablePro
//

import SwiftUI

struct ProjectFolderCandidateList: View {
    let candidates: [ScannedConnectionCandidate]
    @Binding var selection: UUID?

    var body: some View {
        List(candidates, id: \.id, selection: $selection) { candidate in
            row(for: candidate)
                .padding(.vertical, 4)
                .tag(candidate.id)
        }
        .listStyle(.inset)
        .alternatingRowBackgrounds()
    }

    private func row(for candidate: ScannedConnectionCandidate) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            ParsedConnectionSummaryView(parsed: candidate.parsedURL, showsBackground: false)
            HStack(spacing: 6) {
                Image(systemName: "doc.text")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                Text(candidate.sourceRelativePath)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(candidate.sourceKey)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
            }
            if candidate.hasPassword {
                Label(String(localized: "Password found"), systemImage: "key.fill")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            if candidate.placeholderSuspected {
                Label(
                    String(localized: "Looks like a placeholder value"),
                    systemImage: "questionmark.circle"
                )
                .font(.caption2)
                .foregroundStyle(.orange)
            }
            ForEach(candidate.warnings, id: \.self) { warning in
                Label(warning, systemImage: "exclamationmark.triangle")
                    .font(.caption2)
                    .foregroundStyle(.orange)
            }
        }
    }
}
