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
                    Text(LicensePresentation.memberCount(used: team.seatsUsed, limit: team.maxSeats))
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
                        .fontWeight(isCurrentUser(member) ? .semibold : .regular)
                        .lineLimit(1)
                        .truncationMode(.middle)

                    Spacer()

                    Text(roleDescription(member))
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                .padding(.vertical, 2)
            }
            .listStyle(.inset)
            .frame(minHeight: 96, maxHeight: 190)
        } else {
            Text("Nobody has joined this team yet.")
                .foregroundStyle(.secondary)
        }
    }

    /// The signed payload carries the licence owner's email for every member, so this marks the
    /// owner rather than claiming to know which row is the reader on a member's Mac.
    private func isCurrentUser(_ member: LicenseTeamMember) -> Bool {
        member.email == licenseManager.license?.email
    }

    private func roleDescription(_ member: LicenseTeamMember) -> String {
        let role = TeamRole(rawValue: member.role).displayName
        guard isCurrentUser(member) else { return role }
        return String(format: String(localized: "%@ · You"), role)
    }
}
