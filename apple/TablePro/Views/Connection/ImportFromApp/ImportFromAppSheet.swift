//
//  ImportFromAppSheet.swift
//  TablePro
//

import SwiftUI
import TableProImport

struct ImportFromAppSheet: View {
    let onCancel: () -> Void
    let onDone: (ImportOutcome, ImportOrigin) -> Void

    @StateObject private var sources = ForeignSourcePickerModel()
    @State private var step: Step = .sourcePicker
    @State private var pendingCollect: PendingCollect?
    @State private var keychainNotice: KeychainNotice?
    @State private var awaitingNotice: PendingCollect?
    @State private var confirmedNotice: PendingCollect?

    private enum Step {
        case sourcePicker
        case loading(sourceName: String)
        case review(ForeignAppRead, ImportOrigin)
        case error(String)
    }

    private struct PendingCollect {
        let id = UUID()
        let importer: any ForeignAppImporter
        let request: ForeignImportRequest
    }

    init(onCancel: @escaping () -> Void, onDone: @escaping (ImportOutcome, ImportOrigin) -> Void) {
        self.onCancel = onCancel
        self.onDone = onDone
    }

    var body: some View {
        Group {
            switch step {
            case .sourcePicker:
                ImportFromAppSourcePicker(
                    model: sources,
                    onSelect: { importer, request, inventory in
                        beginImport(importer: importer, request: request, inventory: inventory)
                    },
                    onCancel: onCancel
                )

            case .loading(let sourceName):
                loadingView(sourceName: sourceName)

            case .review(let read, let origin):
                ImportReviewStep(
                    title: read.title,
                    banner: read.banner,
                    preview: read.preview,
                    onBack: { step = .sourcePicker },
                    onCancel: onCancel,
                    onFinished: { onDone($0, origin) }
                )

            case .error(let message):
                errorView(message)
            }
        }
        .importSheetFrame()
        .task(id: pendingCollect?.id) {
            guard let pending = pendingCollect else { return }
            await collect(pending)
        }
        .sheet(item: $keychainNotice, onDismiss: keychainNoticeDidDismiss) { notice in
            KeychainNoticeView(
                notice: notice,
                onContinue: {
                    confirmedNotice = awaitingNotice
                    keychainNotice = nil
                },
                onCancel: { keychainNotice = nil }
            )
            .frame(width: 440)
        }
    }

    private func loadingView(sourceName: String) -> some View {
        VStack(spacing: 12) {
            Spacer()
            ProgressView()
                .controlSize(.large)
            Text(String(format: String(localized: "Reading connections from %@…"), sourceName))
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Text(String(localized: "If macOS asks for your login password, click Always Allow on each prompt."))
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)
            Spacer()
            HStack {
                Spacer()
                Button(String(localized: "Cancel")) { cancelImport() }
                    .keyboardShortcut(.cancelAction)
            }
            .padding(12)
        }
    }

    private func errorView(_ message: String) -> some View {
        VStack(spacing: 12) {
            Spacer()
            Image(systemName: "exclamationmark.triangle")
                .font(.title)
                .foregroundStyle(.secondary)
            Text(message)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal)
            Spacer()
            HStack {
                Button(String(localized: "Back")) { step = .sourcePicker }
                Spacer()
                Button(String(localized: "OK")) { onCancel() }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
            }
            .padding(12)
        }
    }

    private func beginImport(importer: any ForeignAppImporter, request: ForeignImportRequest, inventory: ForeignAppInventory) {
        let pending = PendingCollect(importer: importer, request: request)
        if let notice = KeychainNotice.needed(for: importer, request: request, inventory: inventory) {
            awaitingNotice = pending
            keychainNotice = notice
            return
        }
        start(pending)
    }

    // The read starts once the notice has closed, so the first Keychain prompt never sits behind it.
    private func keychainNoticeDidDismiss() {
        let confirmed = confirmedNotice
        awaitingNotice = nil
        confirmedNotice = nil
        if let confirmed {
            start(confirmed)
        }
    }

    private func start(_ pending: PendingCollect) {
        step = .loading(sourceName: pending.importer.displayName)
        pendingCollect = pending
    }

    private func collect(_ pending: PendingCollect) async {
        defer {
            if pendingCollect?.id == pending.id {
                pendingCollect = nil
            }
        }
        do {
            let read = try await ForeignAppImportReader.read(pending.importer, request: pending.request)
            try Task.checkCancellation()
            step = .review(read, pending.importer.importOrigin)
        } catch is CancellationError {
            return
        } catch {
            step = .error(ImportReviewLoader.message(for: error))
        }
    }

    private func cancelImport() {
        pendingCollect = nil
        onCancel()
    }
}
