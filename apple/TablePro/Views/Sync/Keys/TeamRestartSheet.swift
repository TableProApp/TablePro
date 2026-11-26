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
    @StateObject private var selection: TeamRestartSelection

    @Environment(\.dismiss) private var dismiss
    @State private var shownWords: String?

    init(model: TeamKeysModel) {
        self.model = model
        _selection = StateObject(wrappedValue: TeamRestartSelection(service: model.service))
    }

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
                            Text("Compare each member's words with them. Only those whose words match get the new key.")
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

            if !changedNames.isEmpty {
                NoticeLabel(String(
                    format: String(localized: "The keys this Mac has for %@ changed since you compared them. Compare their words again."),
                    changedNames.formatted(.list(type: .and))
                ))
                .padding(.horizontal, 20)
                .padding(.top, 12)
            }

            Divider()
                .padding(.top, changedNames.isEmpty ? 0 : 12)

            DialogFooter {
                Button(String(localized: "Cancel"), role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(String(localized: "Start Over")) {
                    Task { await startOver() }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(model.work != nil)
            }
            .padding(16)
        }
        .frame(width: 520)
    }

    private var changedNames: [String] {
        selection.changed.compactMap { account in candidates.first { $0.account == account }?.displayName }
    }

    @ViewBuilder
    private func row(_ member: TeamMemberKeys) -> some View {
        let included = selection.isIncluded(member.account)
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 1) {
                    Text(verbatim: member.displayName)
                    Text(verbatim: included
                        ? String(localized: "Gets the new key")
                        : TeamKeysPresentation.roleName(member.role))
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 8)
                if included {
                    Button(String(localized: "Leave Out")) { selection.exclude(member.account) }
                        .accessibilityLabel(Text(String(format: String(localized: "Leave out %@"), member.displayName)))
                } else {
                    Button(shownWords == member.account ? String(localized: "Hide Words") : String(localized: "Compare Words")) {
                        shownWords = shownWords == member.account ? nil : member.account
                    }
                    .accessibilityLabel(Text(String(format: String(localized: "Compare %@'s words"), member.displayName)))
                }
            }
            if shownWords == member.account, !included {
                VStack(alignment: .leading, spacing: 8) {
                    TeamFingerprintLoadView(load: selection.words[member.account] ?? .loading)
                    if case .loaded? = selection.words[member.account] {
                        Button(String(localized: "Words Match")) {
                            selection.wordsMatch(member.account)
                            shownWords = nil
                        }
                        .accessibilityLabel(Text(String(format: String(localized: "%@'s words match"), member.displayName)))
                    }
                }
                .padding(.leading, 12)
                .task { await selection.loadWords(member.account) }
            }
        }
    }

    private func startOver() async {
        guard let accounts = await selection.accountsToWrap(in: candidates.map(\.account)) else { return }
        if await model.restart(confirming: accounts) {
            dismiss()
        }
    }
}
