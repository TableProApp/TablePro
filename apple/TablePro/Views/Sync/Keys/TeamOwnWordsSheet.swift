//
//  TeamOwnWordsSheet.swift
//  TablePro
//

import SwiftUI
import TableProFFI

// This account's own fingerprint (core ADR 0056, Pins), for the owner or admin who confirms it: six words to read out,
// and the `TPF1:` code for a phone in the same room.
internal struct TeamOwnWordsSheet: View {
    @ObservedObject var model: TeamKeysModel

    @Environment(\.dismiss) private var dismiss
    @State private var load: TeamFingerprintLoad = .loading

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 14) {
                Text("Your Words")
                    .font(.headline)
                Text("Read these words to the owner or admin who confirms you, or let them take a photo of the code. They are the same on every device of your account.")
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                GroupBox {
                    HStack(alignment: .center, spacing: 20) {
                        TeamFingerprintLoadView(load: load)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        if case .loaded(let fingerprint) = load {
                            TeamFingerprintQRCode(text: fingerprint.qr)
                        }
                    }
                    .padding(8)
                }
            }
            .padding(20)

            Divider()

            DialogFooter {
                Button(String(localized: "Done")) { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
            .padding(16)
        }
        .frame(width: 560)
        .task { await loadWords() }
    }

    private func loadWords() async {
        if case .loaded = load { return }
        do {
            let fingerprint = try await model.service.ownFingerprint()
            load = .loaded(fingerprint)
        } catch {
            load = .failed(TeamKeysFailureText.message(error) ?? String(localized: "Couldn't load your words."))
        }
    }
}
