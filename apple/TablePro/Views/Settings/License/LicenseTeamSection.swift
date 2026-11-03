//
//  LicenseTeamSection.swift
//  TablePro
//

import SwiftUI

// Read-only: invites, removals and seats go through an API the app cannot sign in to, so this links out for them.
struct LicenseTeamSection: View {
    @ObservedObject private var licenseManager = LicenseManager.shared
    @ObservedObject private var teamLibrary = TeamLibrarySyncCoordinator.shared

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
                    warning {
                        Text(message)
                    }

                    Button(String(localized: "Try Again")) {
                        Task { await licenseManager.loadTeam(force: true) }
                    }
                }
            case .loaded:
                roster
            }

            if licenseManager.isFeatureAvailable(.teamLibrary) {
                teamLibraryRows
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

    @ViewBuilder
    private var teamLibraryRows: some View {
        LabeledContent(String(localized: "Team Library")) {
            HStack(spacing: 8) {
                if teamLibrary.isPulling {
                    ProgressView()
                        .controlSize(.small)
                        .accessibilityLabel(String(localized: "Refreshing the team library"))
                } else if let lastRefreshedAt = teamLibrary.lastRefreshedAt {
                    Text(Self.refreshedText(lastRefreshedAt))
                        .foregroundStyle(.secondary)
                }

                Button(String(localized: "Refresh")) {
                    teamLibrary.refresh()
                }
                .disabled(teamLibrary.isPulling)
            }
        }

        if let reason = teamLibrary.lastPullError {
            warning {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Couldn't refresh the team library")
                    Text(reason)
                        .font(.caption)
                        .textSelection(.enabled)
                }
            }
            .accessibilityElement(children: .combine)
        }
    }

    private static func refreshedText(_ date: Date) -> String {
        String(format: String(localized: "Refreshed %@"), date.formatted(.relative(presentation: .named)))
    }

    private func warning<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        Label {
            content()
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        } icon: {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
        }
    }

    // The signed payload carries only the owner's email, so this marks the owner, not whoever reads it.
    private func isCurrentUser(_ member: LicenseTeamMember) -> Bool {
        member.email == licenseManager.license?.email
    }

    private func roleDescription(_ member: LicenseTeamMember) -> String {
        let role = TeamRole(rawValue: member.role).displayName
        guard isCurrentUser(member) else { return role }
        return String(format: String(localized: "%@ (You)"), role)
    }
}
