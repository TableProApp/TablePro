//
//  TeamKeyChangeSheet.swift
//  TablePro
//

import SwiftUI
import TableProFFI

// A key-change alert (core ADR 0056, Pins, Any other change): until the person compares or accepts, this Mac wraps
// nothing to the account. Accepting without comparing is allowed and recorded as a first use.
internal struct TeamKeyChangeSheet: View {
    @ObservedObject var model: TeamKeysModel
    let member: TeamMemberKeys

    private enum Load: Equatable {
        case loading
        case loaded(KeyChangeInfo)
        case settled
        case failed(String)
    }

    @Environment(\.dismiss) private var dismiss
    @State private var change: Load = .loading

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 14) {
                Text(String(format: String(localized: "%@'s Keys Changed"), member.displayName))
                    .font(.headline)
                content
            }
            .padding(20)

            Divider()

            DialogFooter {
                if case .loaded(let info) = change {
                    Button(String(localized: "Accept Without Comparing")) { accept(info, compared: false) }
                        .disabled(model.work != nil)
                }
            } actions: {
                if case .loaded(let info) = change {
                    Button(String(localized: "Cancel"), role: .cancel) { dismiss() }
                        .keyboardShortcut(.cancelAction)
                    Button(String(localized: "Words Match")) { accept(info, compared: true) }
                        .keyboardShortcut(.defaultAction)
                        .disabled(model.work != nil)
                } else {
                    Button(String(localized: "Close")) { dismiss() }
                        .keyboardShortcut(.defaultAction)
                }
            }
            .padding(16)
        }
        .frame(width: 500)
        .task { await load() }
    }

    @ViewBuilder
    private var content: some View {
        switch change {
        case .loading:
            TeamFingerprintLoadView(load: .loading)
        case .settled:
            Text("This key change was already settled on this Mac.")
                .foregroundStyle(.secondary)
        case .failed(let message):
            NoticeLabel(message, severity: .error)
        case .loaded(let info):
            Text(String(
                format: String(
                    localized: """
                        The keys TablePro has for %@ changed. That happens when they reset their keys, and also when someone stands in \
                        for them. Ask them to read their six words and compare them with the new words.
                        """
                ),
                member.displayName
            ))
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)

            GroupBox(String(localized: "New words")) {
                TeamFingerprintWords(words: info.offered.words)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(8)
            }

            GroupBox(String(localized: "Previous words")) {
                TeamFingerprintWords(words: info.pinned.words, prominence: .secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(8)
            }

            if model.canWrapCurrentVersion {
                Text("Accepting also shares the team key with their new keys.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func load() async {
        guard change == .loading else { return }
        do {
            if let info = try await model.service.accountKeyChange(account: member.account) {
                change = .loaded(info)
            } else {
                change = .settled
            }
        } catch {
            change = .failed(TeamKeysFailureText.message(error) ?? String(localized: "Couldn't load the key change."))
        }
    }

    private func accept(_ info: KeyChangeInfo, compared: Bool) {
        Task {
            if await model.acceptKeyChange(member, offeredIk: info.offeredIk, compared: compared) {
                dismiss()
            }
        }
    }
}
