//
//  ConnectionImportSheet.swift
//  TablePro
//

import SwiftUI
import TableProImport

struct ConnectionImportSheet: View {
    let fileURL: URL
    let onFinished: (ImportOutcome) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var phase: Phase = .loading
    @State private var passphrase = ""
    @State private var passphraseError: String?
    @State private var isDecrypting = false

    private enum Phase {
        case loading
        case passphrase(Data)
        case review(ImportPreview)
        case failed(String)
    }

    private enum FileContents: Sendable {
        case encrypted(Data)
        case bundle(ConnectionBundle)
        case unreadable(String)
    }

    var body: some View {
        Group {
            switch phase {
            case .loading:
                ProgressView()
                    .controlSize(.large)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            case .passphrase:
                passphraseView
            case .review(let preview):
                ImportReviewStep(
                    title: String(format: String(localized: "Import from %@"), fileURL.lastPathComponent),
                    banner: nil,
                    preview: preview,
                    onBack: nil,
                    onFinished: onFinished
                )
            case .failed(let message):
                errorView(message)
            }
        }
        .importSheetFrame()
        .task { await loadFile() }
        .task(id: isDecrypting) {
            guard isDecrypting else { return }
            await decryptFile()
            isDecrypting = false
        }
    }

    private func errorView(_ message: String) -> some View {
        VStack(spacing: 12) {
            Spacer()
            Image(systemName: "exclamationmark.triangle")
                .font(.title)
                .foregroundStyle(.secondary)
            Text(verbatim: message)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Spacer()
            HStack {
                Spacer()
                Button(String(localized: "OK")) { dismiss() }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
            }
            .padding(12)
        }
        .padding(.horizontal)
    }

    private var passphraseView: some View {
        VStack(spacing: 16) {
            Spacer()

            Image(systemName: "lock.fill")
                .font(.title)
                .foregroundStyle(.secondary)

            Text("This file is encrypted")
                .font(.body.weight(.semibold))

            Text("Enter the passphrase to decrypt and import connections.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)

            SecureField(String(localized: "Passphrase"), text: $passphrase)
                .textFieldStyle(.roundedBorder)
                .frame(width: 260)
                .onSubmit { requestDecrypt() }

            if let passphraseError {
                Label(passphraseError, systemImage: "exclamationmark.triangle.fill")
                    .font(.subheadline)
                    .foregroundStyle(.orange)
            }

            Spacer()

            HStack {
                Spacer()
                Button(String(localized: "Cancel")) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(String(localized: "Decrypt")) { requestDecrypt() }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(passphrase.isEmpty || isDecrypting)
            }
            .padding(12)
        }
        .padding(.horizontal)
    }

    private func requestDecrypt() {
        guard !passphrase.isEmpty, !isDecrypting else { return }
        isDecrypting = true
    }

    private func loadFile() async {
        guard case .loading = phase else { return }
        switch await Self.readFile(at: fileURL) {
        case .encrypted(let data):
            phase = .passphrase(data)
        case .bundle(let bundle):
            await showReview(of: bundle)
        case .unreadable(let message):
            phase = .failed(message)
        }
    }

    private func decryptFile() async {
        guard case .passphrase(let data) = phase else { return }
        do {
            let bundle = try await Self.decrypt(data, passphrase: passphrase)
            passphraseError = nil
            passphrase = ""
            await showReview(of: bundle)
        } catch {
            passphraseError = error.localizedDescription
            passphrase = ""
        }
    }

    private func showReview(of bundle: ConnectionBundle) async {
        let collected = CollectedImport(bundle: bundle, source: .file(name: fileURL.lastPathComponent))
        do {
            let preview = try await ImportReviewLoader.preview(of: collected)
            phase = .review(preview)
        } catch {
            phase = .failed(ImportReviewLoader.message(for: error))
        }
    }

    @concurrent
    nonisolated private static func readFile(at url: URL) async -> FileContents {
        do {
            let data = try Data(contentsOf: url)
            if ConnectionBundleCodec.isEncrypted(data) {
                return .encrypted(data)
            }
            return .bundle(try ConnectionBundleCodec.decode(data))
        } catch {
            return .unreadable(error.localizedDescription)
        }
    }

    @concurrent
    nonisolated private static func decrypt(_ data: Data, passphrase: String) async throws -> ConnectionBundle {
        try await ConnectionBundleCodec.decode(data, passphrase: passphrase)
    }
}
