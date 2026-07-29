//
//  ProjectFolderCandidateList.swift
//  TablePro
//

import SwiftUI
import TableProPluginKit

struct ProjectFolderCandidateList: View {
    let candidates: [ScannedConnectionCandidate]
    let projectRoot: URL
    @Binding var selection: UUID?

    var body: some View {
        List(selection: $selection) {
            ForEach(candidates) { candidate in
                ProjectFolderCandidateRow(candidate: candidate, projectRoot: projectRoot)
                    .tag(candidate.id)
            }
        }
        .listStyle(.bordered)
    }
}

struct ProjectFolderCandidateRow: View {
    let candidate: ScannedConnectionCandidate
    let projectRoot: URL

    var body: some View {
        HStack(spacing: 8) {
            candidate.parsedURL.type.iconImage
                .frame(width: 16, height: 16)

            VStack(alignment: .leading, spacing: 1) {
                Text(verbatim: destination)
                    .font(.body)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .help(helpText)
                Text(verbatim: provenance)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }

            Spacer(minLength: 8)

            accessories
        }
        .padding(.vertical, 2)
    }

    @ViewBuilder
    private var accessories: some View {
        HStack(spacing: 4) {
            if candidate.placeholderSuspected {
                accessory(
                    "questionmark.circle.fill",
                    label: String(localized: "Looks like a placeholder value"),
                    tint: .orange
                )
            }
            if let warning = candidate.warnings.first {
                accessory("exclamationmark.triangle.fill", label: warning, tint: .orange)
            }
            if candidate.hasPassword {
                accessory("key.fill", label: String(localized: "Password found"), tint: nil)
            }
        }
    }

    @ViewBuilder
    private func accessory(_ systemName: String, label: String, tint: Color?) -> some View {
        let symbol = Image(systemName: systemName)
            .imageScale(.medium)
            .help(label)
            .accessibilityLabel(label)
        if let tint {
            symbol.selectionAwareForeground(tint)
        } else {
            symbol.foregroundStyle(.secondary)
        }
    }

    private var snapshot: PluginMetadataSnapshot? {
        PluginMetadataRegistry.shared.snapshot(forTypeId: candidate.parsedURL.type.rawValue)
    }

    private var typeName: String {
        snapshot?.displayName ?? candidate.parsedURL.type.rawValue
    }

    private var destination: String {
        let parsed = candidate.parsedURL
        switch snapshot?.connectionMode ?? .network {
        case .fileBased:
            return displayPath(parsed.database)
        case .apiOnly:
            return parsed.host.isEmpty ? typeName : parsed.host
        case .network:
            if let multiHost = parsed.multiHost, multiHost.contains(",") {
                return multiHost
            }
            guard !parsed.host.isEmpty else {
                return parsed.database.isEmpty ? typeName : parsed.database
            }
            return parsed.port.map { "\(parsed.host):\($0)" } ?? parsed.host
        }
    }

    private var provenance: String {
        [typeName, candidate.sourceRelativePath, candidate.sourceKey].joined(separator: " · ")
    }

    private var helpText: String {
        let parsed = candidate.parsedURL
        guard (snapshot?.connectionMode ?? .network) == .fileBased, !parsed.database.isEmpty else {
            return provenance
        }
        return parsed.database
    }

    private func displayPath(_ path: String) -> String {
        guard !path.isEmpty else {
            return typeName
        }
        let root = projectRoot.standardizedFileURL.path
        if path.hasPrefix(root + "/") {
            return String(path.dropFirst(root.count + 1))
        }
        return (path as NSString).abbreviatingWithTildeInPath
    }
}
