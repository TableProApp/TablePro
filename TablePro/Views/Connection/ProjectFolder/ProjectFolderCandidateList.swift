//
//  ProjectFolderCandidateList.swift
//  TablePro
//

import SwiftUI

struct ProjectFolderCandidateList: View {
    let candidates: [ScannedConnectionCandidate]
    @Binding var selection: UUID?

    var body: some View {
        List(selection: $selection) {
            ForEach(candidates) { candidate in
                ProjectFolderCandidateRow(candidate: candidate)
                    .tag(candidate.id)
            }
        }
        .listStyle(.inset)
    }
}

struct ProjectFolderCandidateRow: View {
    let candidate: ScannedConnectionCandidate

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            ParsedConnectionSummaryView(parsed: candidate.parsedURL, showsBackground: false)
            sourceLine
            if candidate.hasPassword {
                badge(String(localized: "Password found"), systemImage: "key.fill", tint: .secondary)
            }
            if candidate.placeholderSuspected {
                badge(
                    String(localized: "Looks like a placeholder value"),
                    systemImage: "questionmark.circle",
                    tint: .orange
                )
            }
            ForEach(candidate.warnings, id: \.self) { warning in
                badge(warning, systemImage: "exclamationmark.triangle", tint: .orange)
            }
        }
        .padding(.vertical, 4)
    }

    private var sourceLine: some View {
        HStack(spacing: 6) {
            Image(systemName: "doc.text")
                .font(.caption2)
                .selectionAwareForeground(Color(nsColor: .tertiaryLabelColor), emphasizedOpacity: 0.6)
            Text(candidate.sourceRelativePath)
                .font(.caption2)
                .selectionAwareForeground(Color(nsColor: .secondaryLabelColor), emphasizedOpacity: 0.85)
                .lineLimit(1)
                .truncationMode(.middle)
            Text(candidate.sourceKey)
                .font(.caption2)
                .selectionAwareForeground(Color(nsColor: .tertiaryLabelColor), emphasizedOpacity: 0.6)
                .lineLimit(1)
        }
    }

    private func badge(_ text: String, systemImage: String, tint: Color) -> some View {
        Label(text, systemImage: systemImage)
            .font(.caption2)
            .selectionAwareForeground(tint, emphasizedOpacity: 0.85)
    }
}
