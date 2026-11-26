//
//  TeamMemberConfirmSheet.swift
//  TablePro
//

import SwiftUI
import TableProFFI

// Confirming a member is an owner's or admin's action, as Bitwarden's Confirm step is (core ADR 0056, Teams): the
// words of the key this Mac pinned for them, compared out of band or by reading their code, then a wrap of the
// current team key version to that key.
internal struct TeamMemberConfirmSheet: View {
    @ObservedObject var model: TeamKeysModel
    let member: TeamMemberKeys

    @Environment(\.dismiss) private var dismiss
    @State private var words: TeamFingerprintLoad = .loading
    @State private var codeCheck: TeamCodeComparison?
    @State private var lastPhotoHadNoCode = false
    @State private var isReadingCode = false
    @State private var showsMismatch = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 14) {
                Text(String(format: String(localized: "Confirm %@"), member.displayName))
                    .font(.headline)
                Text(String(
                    format: String(
                        localized: "Ask %@ to read the six words under Settings > Account > Teams > %@ > Show My Words. Confirm only if they match these."
                    ),
                    member.displayName,
                    model.team.name
                ))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

                GroupBox {
                    TeamFingerprintLoadView(load: words)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(8)
                }

                VStack(alignment: .leading, spacing: 8) {
                    Text("In the same room? Take a photo of their code with your iPhone or iPad instead.")
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    HStack(spacing: 10) {
                        TeamContinuityCameraButton(title: String(localized: "Read Their Code")) { image in
                            Task { await read(image) }
                        }
                        .fixedSize()
                        .disabled(isReadingCode)
                        if isReadingCode {
                            ProgressView()
                                .controlSize(.small)
                                .accessibilityLabel(Text("Reading the code"))
                        }
                    }
                    codeCheckLabel
                }
            }
            .padding(20)

            Divider()

            DialogFooter {
                Button(String(localized: "Words Don't Match")) { showsMismatch = true }
                    .disabled(!hasWords)
            } actions: {
                Button(String(localized: "Cancel"), role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(String(localized: "Confirm")) {
                    Task {
                        if await model.confirm(member) { dismiss() }
                    }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!canConfirm)
            }
            .padding(16)
        }
        .frame(width: 480)
        .task { await loadWords() }
        .alert(String(format: String(localized: "Don't Confirm %@"), member.displayName), isPresented: $showsMismatch) {
            Button(String(localized: "Close")) { dismiss() }
        } message: {
            Text("The keys this Mac has for them aren't the keys they hold, so someone may be standing in for them. Tell the person who runs your TablePro server.")
        }
    }

    @ViewBuilder
    private var codeCheckLabel: some View {
        switch codeCheck {
        case .matches:
            NoticeLabel(String(localized: "Their code matches. You can confirm them."), severity: .success)
        case .differs:
            NoticeLabel(String(localized: "Their code doesn't match the keys this Mac has for them. Don't confirm them."), severity: .error)
            if lastPhotoHadNoCode {
                NoticeLabel(String(localized: "The last photo had no TablePro code in it."), severity: .info)
            }
        case .unreadable:
            NoticeLabel(String(localized: "No TablePro code was found in the photo. Try again closer to the screen."))
        case nil:
            EmptyView()
        }
    }

    private var hasWords: Bool {
        if case .loaded = words { return true }
        return false
    }

    // A code still being read may yet differ, so Confirm waits for its answer.
    private var canConfirm: Bool {
        hasWords && !isReadingCode && codeCheck != .differs && model.work == nil
    }

    private func loadWords() async {
        guard !hasWords else { return }
        do {
            let fingerprint = try await model.service.accountFingerprint(account: member.account)
            words = .loaded(fingerprint)
        } catch {
            words = .failed(TeamKeysFailureText.message(error) ?? String(localized: "Couldn't load their words."))
        }
    }

    private func read(_ image: CGImage) async {
        isReadingCode = true
        defer { isReadingCode = false }
        let next: TeamCodeComparison
        if let text = await TeamFingerprintCode.text(in: image) {
            next = await model.compareCode(text, with: member)
        } else {
            next = .unreadable
        }
        lastPhotoHadNoCode = next == .unreadable
        codeCheck = TeamCodeComparison.settled(after: codeCheck, reading: next)
    }
}
