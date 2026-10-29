//
//  TeamLibraryConflictSheet.swift
//  TablePro
//

import SwiftUI
import TableProCloudAPI
import TableProImport

// What the sheet shows for one side of a conflict.
internal struct TeamLibraryVersionSummary: Equatable {
    struct Line: Equatable, Identifiable {
        let label: String
        let value: String
        var isCode = false

        var id: String { label }
    }

    let lines: [Line]
    // Set when this side removes the item, or the team no longer holds it.
    let removal: String?
}

internal struct TeamLibraryConflictPresentation: Equatable {
    let title: String
    let message: String
    let mine: TeamLibraryVersionSummary
    let theirs: TeamLibraryVersionSummary

    init(conflict: TeamLibraryConflict, current: TeamLibraryChange?, teamName: String?) {
        let mineData = conflict.edit.data?.additionalProperties
        let kind = conflict.edit.kind.rawValue
        let name = TeamLibraryPayload.name(kind: kind, data: mineData)
            ?? TeamLibraryPayload.name(kind: kind, data: current?.dataValues)
            ?? conflict.edit.clientId
        title = String(format: String(localized: "“%@” changed since you last synced"), name)
        let team = teamName ?? String(localized: "your team")
        message = String(
            format: String(localized: "Someone in %@ changed this item after TablePro last downloaded the team library. Choose the version the team library keeps."),
            team
        )
        mine = conflict.edit.op == .delete
            ? TeamLibraryVersionSummary(lines: [], removal: String(localized: "Removed from the team library"))
            : TeamLibraryVersionSummary(lines: Self.lines(kind: kind, data: mineData), removal: nil)
        if let current, !current.deleted {
            theirs = TeamLibraryVersionSummary(lines: Self.lines(kind: kind, data: current.dataValues), removal: nil)
        } else if current?.deleted == true {
            theirs = TeamLibraryVersionSummary(lines: [], removal: String(localized: "Deleted from the team library"))
        } else {
            theirs = TeamLibraryVersionSummary(lines: [], removal: String(localized: "No longer in the team library"))
        }
    }

    private static func lines(kind: String, data: TeamLibraryData?) -> [TeamLibraryVersionSummary.Line] {
        switch kind {
        case TeamLibraryKind.folder:
            guard let folder = TeamLibraryPayload.decode(TeamLibraryFolderData.self, from: data) else { return [] }
            return [TeamLibraryVersionSummary.Line(label: String(localized: "Folder"), value: folder.name)]
        case TeamLibraryKind.query:
            guard let query = TeamLibraryPayload.decode(TeamLibraryQueryData.self, from: data) else { return [] }
            var lines = [TeamLibraryVersionSummary.Line(label: String(localized: "Name"), value: query.name)]
            if let keyword = query.keyword, !keyword.isEmpty {
                lines.append(TeamLibraryVersionSummary.Line(label: String(localized: "Keyword"), value: keyword))
            }
            lines.append(TeamLibraryVersionSummary.Line(label: "SQL", value: query.query, isCode: true))
            return lines
        case TeamLibraryKind.connection:
            guard let settings = TeamLibraryPayload.decode(ExportableConnection.self, from: data) else { return [] }
            var lines = [TeamLibraryVersionSummary.Line(label: String(localized: "Name"), value: settings.name)]
            if !settings.host.isEmpty {
                lines.append(TeamLibraryVersionSummary.Line(label: String(localized: "Host"), value: "\(settings.host):\(settings.port)"))
            }
            if !settings.database.isEmpty {
                lines.append(TeamLibraryVersionSummary.Line(label: String(localized: "Database"), value: settings.database))
            }
            if !settings.username.isEmpty {
                lines.append(TeamLibraryVersionSummary.Line(label: String(localized: "User"), value: settings.username))
            }
            return lines
        default:
            return []
        }
    }
}

// Shown after a publish the team library refused for items someone else changed meanwhile, one conflict at a time.
internal struct TeamLibraryConflictSheet: View {
    @ObservedObject var sync: TeamLibrarySync
    @Environment(\.dismiss) private var dismiss
    @State private var isResolving = false

    var body: some View {
        Group {
            if let conflict = sync.conflicts.first {
                TeamLibraryConflictContent(
                    presentation: TeamLibraryConflictPresentation(
                        conflict: conflict,
                        current: sync.current(for: conflict),
                        teamName: sync.teamName(of: conflict.teamID)
                    ),
                    remaining: sync.conflicts.count,
                    isResolving: isResolving,
                    decideLater: { dismiss() },
                    keep: { keepingMine in resolve(conflict, keepingMine: keepingMine) }
                )
            } else {
                Color.clear
                    .frame(width: 1, height: 1)
                    .onAppear { dismiss() }
            }
        }
        .onValueChange(of: sync.conflicts.isEmpty) { _, isEmpty in
            if isEmpty { dismiss() }
        }
    }

    private func resolve(_ conflict: TeamLibraryConflict, keepingMine: Bool) {
        isResolving = true
        Task {
            await sync.resolve(conflict, keepingMine: keepingMine)
            isResolving = false
        }
    }
}

internal struct TeamLibraryConflictContent: View {
    let presentation: TeamLibraryConflictPresentation
    let remaining: Int
    let isResolving: Bool
    let decideLater: () -> Void
    let keep: (_ keepingMine: Bool) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: "exclamationmark.triangle")
                    .font(.largeTitle)
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)

                VStack(alignment: .leading, spacing: 4) {
                    Text(presentation.title)
                        .font(.headline)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityAddTraits(.isHeader)
                    Text(presentation.message)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            HStack(alignment: .top, spacing: 12) {
                TeamLibraryVersionColumn(
                    title: String(localized: "Your Version"),
                    summary: presentation.mine,
                    identifier: "team-library-conflict-mine"
                )
                TeamLibraryVersionColumn(
                    title: String(localized: "Team's Version"),
                    summary: presentation.theirs,
                    identifier: "team-library-conflict-theirs"
                )
            }

            HStack(spacing: 8) {
                Button(String(localized: "Decide Later"), action: decideLater)
                    .keyboardShortcut(.cancelAction)
                    .accessibilityIdentifier("team-library-conflict-later")
                if remaining > 1 {
                    Text(String(format: String(localized: "%d conflicts left"), remaining))
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if isResolving {
                    ProgressView()
                        .controlSize(.small)
                        .accessibilityLabel(Text("Saving your choice"))
                }
                Button(String(localized: "Keep Mine")) { keep(true) }
                    .accessibilityHint(Text("Replaces the team's version with yours"))
                    .accessibilityIdentifier("team-library-conflict-keep-mine")
                Button(String(localized: "Keep Theirs")) { keep(false) }
                    .keyboardShortcut(.defaultAction)
                    .accessibilityHint(Text("Leaves the team's version as it is"))
                    .accessibilityIdentifier("team-library-conflict-keep-theirs")
            }
            .disabled(isResolving)
        }
        .padding(20)
        .frame(width: 560)
    }
}

private struct TeamLibraryVersionColumn: View {
    let title: String
    let summary: TeamLibraryVersionSummary
    let identifier: String

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.subheadline.weight(.semibold))
            VStack(alignment: .leading, spacing: 6) {
                if let removal = summary.removal {
                    Label(removal, systemImage: "trash")
                        .foregroundStyle(.secondary)
                }
                ForEach(summary.lines) { line in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(line.label)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        if line.isCode {
                            ScrollView {
                                Text(line.value)
                                    .font(.system(.callout, design: .monospaced))
                                    .textSelection(.enabled)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                            .frame(maxHeight: 120)
                        } else {
                            Text(line.value)
                                .lineLimit(2)
                                .textSelection(.enabled)
                        }
                    }
                    .accessibilityElement(children: .combine)
                }
            }
            .padding(10)
            .frame(maxWidth: .infinity, minHeight: 80, alignment: .topLeading)
            .background(.background, in: RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color(nsColor: .separatorColor)))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text(title))
        .accessibilityIdentifier(identifier)
    }
}
