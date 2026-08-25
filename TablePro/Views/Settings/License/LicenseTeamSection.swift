//
//  LicenseTeamSection.swift
//  TablePro
//

import SwiftUI

/// Who is on a Team license, read-only.
///
/// Invites, removals and seat counts are written through a token-authenticated API the app cannot
/// authenticate against, so this reports the roster and links out for anything that changes it.
struct LicenseTeamSection: View {
    private let licenseManager = LicenseManager.shared

    var body: some View {
        Section {
            switch licenseManager.teamListState {
            case .idle, .loading:
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Loading team…")
                        .foregroundStyle(.secondary)
                }
            case .failed(let message):
                VStack(alignment: .leading, spacing: 8) {
                    Label(message, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)

                    Button(String(localized: "Try Again")) {
                        Task { await licenseManager.loadTeam(force: true) }
                    }
                }
            case .loaded:
                roster
            }
        } header: {
            HStack {
                Text("Team")
                Spacer()
                if let team = licenseManager.team, licenseManager.teamListState == .loaded {
                    Text(LicensePresentation.seatCount(used: team.seatsUsed, limit: team.maxSeats))
                        .foregroundStyle(.secondary)
                }
            }
        }
        .task { await licenseManager.loadTeam() }
    }

    @ViewBuilder
    private var roster: some View {
        if let team = licenseManager.team, !team.members.isEmpty {
            List(team.members) { member in
                HStack(spacing: 10) {
                    Text(member.email)
                        .lineLimit(1)
                        .truncationMode(.middle)

                    Spacer()

                    Text(TeamRole(rawValue: member.role).displayName)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                .padding(.vertical, 2)
            }
            .listStyle(.inset)
            .frame(minHeight: 96, maxHeight: 190)
            .accessibilityIdentifier("license-team-list")
        } else {
            Text("Nobody has joined this team yet.")
                .foregroundStyle(.secondary)
        }
    }
}
