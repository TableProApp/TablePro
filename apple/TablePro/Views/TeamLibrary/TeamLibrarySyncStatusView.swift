//
//  TeamLibrarySyncStatusView.swift
//  TablePro
//

import SwiftUI

// The trailing part of a "Team Library" header: a spinner while it syncs, a warning when the last sync failed, and a
// button that opens the conflicts a publish left.
internal struct TeamLibrarySyncStatusView: View {
    @ObservedObject var sync: TeamLibrarySync
    let resolveConflicts: () -> Void

    var body: some View {
        TeamLibrarySyncStatusContent(
            status: sync.status,
            conflictCount: sync.conflicts.count,
            resolveConflicts: resolveConflicts
        )
    }
}

internal struct TeamLibrarySyncStatusContent: View {
    let status: TeamLibrarySyncStatus
    let conflictCount: Int
    let resolveConflicts: () -> Void

    var body: some View {
        HStack(spacing: 6) {
            switch status {
            case .syncing:
                ProgressView()
                    .controlSize(.mini)
                    .accessibilityLabel(Text("Syncing the team library"))
                    .accessibilityIdentifier("team-library-status-syncing")
            case .failed(let failure):
                Image(systemName: "exclamationmark.arrow.triangle.2.circlepath")
                    .foregroundStyle(.secondary)
                    .help(TeamLibrarySyncDescription.failure(failure))
                    .accessibilityLabel(Text(TeamLibrarySyncDescription.failure(failure)))
                    .accessibilityIdentifier("team-library-status-failed")
            case .idle, .synced:
                EmptyView()
            }
            if conflictCount > 0 {
                Button(action: resolveConflicts) {
                    Label(TeamLibrarySyncDescription.conflicts(conflictCount), systemImage: "exclamationmark.triangle.fill")
                        .labelStyle(.titleAndIcon)
                }
                .buttonStyle(.borderless)
                .controlSize(.small)
                .foregroundStyle(.orange)
                .help(String(localized: "Choose which version the team library keeps"))
                .accessibilityIdentifier("team-library-resolve-conflicts")
            }
        }
        .font(.caption)
    }
}

internal enum TeamLibrarySyncDescription {
    static func conflicts(_ count: Int) -> String {
        count == 1
            ? String(localized: "1 Conflict")
            : String(format: String(localized: "%d Conflicts"), count)
    }

    static func failure(_ failure: TeamLibraryFailure) -> String {
        switch failure {
        case .offline, .rateLimited, .server:
            return String(format: String(localized: "%@ TablePro tries again shortly."), TeamLibraryPublishing.failureText(failure))
        case .signedOut, .unreadable, .writeForbidden, .cursorExpired, .refused:
            return TeamLibraryPublishing.failureText(failure)
        }
    }

    // The header's tooltip, so the time of the last sync is a hover away without taking room in the sidebar.
    static func help(for status: TeamLibrarySyncStatus, now: Date = Date()) -> String? {
        switch status {
        case .idle:
            return nil
        case .syncing:
            return String(localized: "Syncing the team library…")
        case .synced(let date):
            let elapsed = date.formatted(.relative(presentation: .named, unitsStyle: .wide))
            return String(format: String(localized: "Team library updated %@"), elapsed)
        case .failed(let failure):
            return Self.failure(failure)
        }
    }
}

// The "Team Library" section header of the welcome window and the Favorites sidebar.
internal struct TeamLibraryHeader: View {
    let title: String
    let font: Font
    let resolveConflicts: () -> Void
    @ObservedObject private var sync = TeamLibrarySync.shared

    init(title: String, font: Font, resolveConflicts: @escaping () -> Void) {
        self.title = title
        self.font = font
        self.resolveConflicts = resolveConflicts
    }

    var body: some View {
        HStack(spacing: 6) {
            Text(title)
                .font(font)
                .foregroundStyle(.secondary)
                .accessibilityAddTraits(.isHeader)
            Spacer(minLength: 4)
            TeamLibrarySyncStatusView(sync: sync, resolveConflicts: resolveConflicts)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .help(TeamLibrarySyncDescription.help(for: sync.status) ?? "")
    }
}
