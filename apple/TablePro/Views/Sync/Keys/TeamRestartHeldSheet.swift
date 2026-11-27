//
//  TeamRestartHeldSheet.swift
//  TablePro
//

import SwiftUI
import TableProFFI

// A team restart this Mac holds (core ADR 0064): it takes the new key only once the person compares the restarting
// owner's six words and accepts. Accepting without comparing is not offered.
internal struct TeamRestartHeldSheet: View {
    @ObservedObject var model: TeamKeysModel

    private enum Load: Equatable {
        case loading
        case loaded(HeldRestartInfo)
        case settled
        case failed(String)
    }

    @Environment(\.dismiss) private var dismiss
    @State private var held: Load = .loading

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 14) {
                Text("The Team Key Was Started Over")
                    .font(.headline)
                content
            }
            .padding(20)

            Divider()

            DialogFooter {
                if case .loaded(let info) = held {
                    Button(String(localized: "Not Now"), role: .cancel) { dismiss() }
                        .keyboardShortcut(.cancelAction)
                    Button(String(localized: "Words Match")) {
                        Task {
                            if await model.acceptRestart(signerIk: info.signerIk) { dismiss() }
                        }
                    }
                    .keyboardShortcut(.defaultAction)
                    .disabled(model.work != nil)
                } else {
                    Button(String(localized: "Close")) { dismiss() }
                        .keyboardShortcut(.defaultAction)
                }
            }
            .padding(16)
        }
        .frame(width: 480)
        .task { await load() }
    }

    @ViewBuilder
    private var content: some View {
        switch held {
        case .loading:
            TeamFingerprintLoadView(load: .loading)
        case .settled:
            Text("This Mac no longer holds a restarted team key.")
                .foregroundStyle(.secondary)
        case .failed(let message):
            NoticeLabel(message, severity: .error)
        case .loaded(let info):
            let signer = model.snapshot?.member(info.signer)
            if signer == nil {
                NoticeLabel(TeamKeysPresentation.restartHeldText(signer: nil), severity: .warning)
            } else {
                Text(TeamKeysPresentation.restartHeldText(signer: signer))
                    .fixedSize(horizontal: false, vertical: true)
            }

            Text(String(
                format: String(
                    localized: """
                        Ask %@ to read their six words. Until the words match and you accept, this Mac keeps the passwords it already \
                        has for %@ and saves no new ones there.
                        """
                ),
                signer?.displayName ?? String(localized: "the owner"),
                model.team.name
            ))
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)

            GroupBox {
                TeamFingerprintWords(words: info.words.words)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(8)
            }
        }
    }

    private func load() async {
        guard held == .loading else { return }
        do {
            if let info = try await model.service.heldTeamRestart(team: model.team.id) {
                held = .loaded(info)
            } else {
                held = .settled
            }
        } catch {
            held = .failed(TeamKeysFailureText.message(error) ?? String(localized: "Couldn't load the restart."))
        }
    }
}
