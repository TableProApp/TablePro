//
//  TeamRestartSheet.swift
//  TablePro
//

import SwiftUI
import TableProFFI

// No holder left (core ADR 0056, Teams): an owner starts the key over with `start` 1 and wraps it to the members it
// confirms, each after a comparison of their words, so nothing is wrapped to someone no person looked at.
internal struct TeamRestartSheet: View {
    @ObservedObject var model: TeamKeysModel

    @Environment(\.dismiss) private var dismiss
    @State private var included: Set<String> = []
    @State private var shownWords: String?
    @State private var words: [String: TeamFingerprintLoad] = [:]

    private var candidates: [TeamMemberKeys] {
        model.snapshot.map(TeamKeysPresentation.restartCandidates) ?? []
    }

    private var waitingForKeyChange: [TeamMemberKeys] {
        model.snapshot.map(TeamKeysPresentation.restartWaitsForKeyChange) ?? []
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 8) {
                Text("Start the Team Key Over")
                    .font(.headline)
                Text(String(
                    format: String(
                        localized: """
                            No one on %@ holds the current team key, so it can't be passed on. Starting over makes a new key and shares it \
                            with the members you include. Passwords saved under the old key stay readable only where a device still has \
                            that key.
                            """
                    ),
                    model.team.name
                ))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(20)

            Divider()

            Form {
                Section {
                    if candidates.isEmpty {
                        Text("No other member has set up their keys yet. You can start over now and confirm them later.")
                            .foregroundStyle(.secondary)
                    }
                    ForEach(candidates) { member in
                        row(member)
                    }
                } footer: {
                    VStack(alignment: .leading, spacing: 4) {
                        if !candidates.isEmpty {
                            Text("Include someone only after comparing their words with them.")
                        }
                        if !waitingForKeyChange.isEmpty {
                            Text(String(
                                format: String(localized: "Left out until you compare their new keys on the team page: %@."),
                                waitingForKeyChange.map(\.displayName).formatted(.list(type: .and))
                            ))
                        }
                    }
                }
            }
            .formStyle(.grouped)
            // A grouped Form answers any proposal with the whole height, so it alone is capped (#2930).
            .frame(maxHeight: 360)

            Divider()

            DialogFooter {
                Button(String(localized: "Cancel"), role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(String(localized: "Start Over")) {
                    Task {
                        let accounts = candidates.map(\.account).filter(included.contains)
                        if await model.restart(confirming: accounts) { dismiss() }
                    }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(model.work != nil)
            }
            .padding(16)
        }
        .frame(width: 520)
    }

    @ViewBuilder
    private func row(_ member: TeamMemberKeys) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Toggle(isOn: inclusion(member)) {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(verbatim: member.displayName)
                        Text(verbatim: TeamKeysPresentation.roleName(member.role))
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                }
                .toggleStyle(.checkbox)
                Spacer(minLength: 8)
                Button(shownWords == member.account ? String(localized: "Hide Words") : String(localized: "Compare Words")) {
                    toggleWords(member)
                }
                .accessibilityLabel(Text(String(format: String(localized: "Compare %@'s words"), member.displayName)))
            }
            if shownWords == member.account {
                TeamFingerprintLoadView(load: words[member.account] ?? .loading)
                    .padding(.leading, 20)
                    .task { await loadWords(member) }
            }
        }
    }

    private func inclusion(_ member: TeamMemberKeys) -> Binding<Bool> {
        Binding(
            get: { included.contains(member.account) },
            set: { isOn in
                if isOn {
                    included.insert(member.account)
                } else {
                    included.remove(member.account)
                }
            }
        )
    }

    private func toggleWords(_ member: TeamMemberKeys) {
        shownWords = shownWords == member.account ? nil : member.account
    }

    private func loadWords(_ member: TeamMemberKeys) async {
        if case .loaded? = words[member.account] { return }
        do {
            let fingerprint = try await model.service.accountFingerprint(account: member.account)
            words[member.account] = .loaded(fingerprint)
        } catch {
            words[member.account] = .failed(
                TeamKeysFailureText.message(error) ?? String(localized: "Couldn't load their words.")
            )
        }
    }
}
