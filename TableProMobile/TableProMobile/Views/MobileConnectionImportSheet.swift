import SwiftUI
import TableProImport
import TableProModels

struct MobileConnectionImportSheet: View {
    let fileURL: URL
    var onImported: ((Int) -> Void)?

    @Environment(AppState.self) private var appState
    @Environment(\.dismiss) private var dismiss

    @State private var phase: Phase = .loading
    @State private var review: Review?
    @State private var encryptedData: Data?
    @State private var passphrase = ""
    @State private var passphraseError: String?
    @State private var isDecrypting = false
    @State private var isImporting = false

    private enum Phase: Equatable {
        case loading
        case passphrase
        case review
        case failed(String)
    }

    private struct Review {
        let preview: ImportPreview
        var selection: ImportSelection

        var plan: ImportPlan {
            ImportPlanner.plan(preview, selection: selection)
        }
    }

    nonisolated private enum FileContents: Sendable {
        case encrypted(Data)
        case bundle(ConnectionBundle)
        case unreadable(String)
    }

    var body: some View {
        NavigationStack {
            content
                .navigationTitle(Text("Import Connections"))
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button(String(localized: "Cancel")) { dismiss() }
                    }
                    ToolbarItem(placement: .confirmationAction) {
                        if phase == .review, let review {
                            if isImporting {
                                ProgressView()
                            } else {
                                Button(String(localized: "Import")) { isImporting = true }
                                    .disabled(review.plan.isEmpty)
                            }
                        }
                    }
                }
        }
        .task { await loadFile() }
        .task(id: isDecrypting) {
            guard isDecrypting else { return }
            await decrypt()
            isDecrypting = false
        }
        .task(id: isImporting) {
            guard isImporting else { return }
            await performImport()
            isImporting = false
        }
    }

    @ViewBuilder
    private var content: some View {
        switch phase {
        case .loading:
            ProgressView().controlSize(.large)
        case .passphrase:
            passphraseView
        case .failed(let message):
            ContentUnavailableView {
                Label(String(localized: "Can't Import"), systemImage: "exclamationmark.triangle")
            } description: {
                Text(message)
            }
        case .review:
            if let review {
                reviewList(review)
            }
        }
    }

    private var passphraseView: some View {
        Form {
            Section {
                SecureField(String(localized: "Passphrase"), text: $passphrase)
                    .textContentType(.password)
                    .onSubmit(requestDecryption)
            } header: {
                Text("This file is encrypted")
            } footer: {
                if let passphraseError {
                    Text(passphraseError).foregroundStyle(.red)
                } else {
                    Text("Enter the passphrase to decrypt and import connections.")
                }
            }
            HStack {
                Button(String(localized: "Decrypt"), action: requestDecryption)
                    .disabled(passphrase.isEmpty || isDecrypting)
                if isDecrypting {
                    Spacer()
                    ProgressView()
                }
            }
        }
    }

    private func reviewList(_ review: Review) -> some View {
        List {
            Section {
                ForEach(review.preview.connections) { row in
                    connectionRow(row, in: review)
                }
            } footer: {
                if !review.preview.collected.bundle.savedQueries.isEmpty {
                    Text("This file also holds saved queries, which import only on a Mac.")
                }
            }
        }
        .disabled(isImporting)
    }

    private func connectionRow(_ row: ConnectionRow, in review: Review) -> some View {
        let isSelected = review.selection.resolution(for: row.ref) != nil
        return HStack(spacing: 12) {
            Button {
                setSelected(!isSelected, row)
            } label: {
                HStack(spacing: 12) {
                    Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                        .foregroundStyle(isSelected ? Color.accentColor : Color.secondary)

                    DatabaseIconView(type: DatabaseType(rawValue: row.settings.type), size: 18)
                        .frame(width: 28, height: 28)

                    VStack(alignment: .leading, spacing: 2) {
                        Text(row.settings.name)
                            .lineLimit(1)
                        Text(Self.subtitle(for: row))
                            .font(.caption)
                            .foregroundStyle(Self.needsAttention(row) ? Color.orange : Color.secondary)
                            .lineLimit(1)
                    }

                    Spacer()
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if isSelected, row.duplicate != nil {
                Picker("", selection: resolutionBinding(for: row, in: review)) {
                    ForEach(review.selection.offeredResolutions(for: row), id: \.self) { resolution in
                        Text(Self.label(for: resolution)).tag(resolution)
                    }
                }
                .pickerStyle(.menu)
                .labelsHidden()
            }
        }
    }

    private static func subtitle(for row: ConnectionRow) -> String {
        if let typeId = row.unsupportedTypeId {
            return String(format: String(localized: "TablePro doesn't support “%@” connections"), typeId)
        }
        if let duplicate = row.duplicate {
            return String(format: String(localized: "Matches “%@”"), duplicate.name)
        }
        return row.warnings.first ?? "\(row.settings.host):\(row.settings.port)"
    }

    private static func needsAttention(_ row: ConnectionRow) -> Bool {
        row.unsupportedTypeId != nil || row.duplicate != nil || !row.warnings.isEmpty
    }

    private static func label(for resolution: ConnectionResolution) -> String {
        switch resolution {
        case .add: String(localized: "Add")
        case .addCopy: String(localized: "As Copy")
        case .replace: String(localized: "Replace")
        case .keepExisting: String(localized: "Keep Existing, Add Queries")
        }
    }

    private static func message(for error: any Error) -> String {
        if error is ImportStoreError {
            return String(localized: "TablePro could not read your connection library, so nothing was imported.")
        }
        return error.localizedDescription
    }

    private static func message(for failure: ImportFailure) -> String {
        switch failure {
        case .libraryUnreadable:
            String(localized: "TablePro could not read your connection library, so nothing was imported.")
        case .connectionsNotSaved:
            String(localized: "The connections could not be saved.")
        case .savedQueriesNotSaved:
            String(localized: "The saved queries could not be saved.")
        }
    }

    // MARK: - State helpers

    private func setSelected(_ selected: Bool, _ row: ConnectionRow) {
        guard let preview = review?.preview else { return }
        review?.selection.setSelected(selected, connection: row.ref, in: preview)
    }

    private func resolutionBinding(for row: ConnectionRow, in review: Review) -> Binding<ConnectionResolution> {
        Binding(
            get: { self.review?.selection.resolution(for: row.ref) ?? row.resolutions.first ?? .addCopy },
            set: { resolution in
                _ = self.review?.selection.resolve(row.ref, as: resolution, in: review.preview)
            }
        )
    }

    // MARK: - Actions

    private func loadFile() async {
        guard phase == .loading else { return }
        switch await Self.readFile(at: fileURL) {
        case .encrypted(let data):
            encryptedData = data
            phase = .passphrase
        case .bundle(let bundle):
            await showReview(of: bundle)
        case .unreadable(let message):
            phase = .failed(message)
        }
    }

    private func requestDecryption() {
        guard !passphrase.isEmpty, !isDecrypting else { return }
        passphraseError = nil
        isDecrypting = true
    }

    private func decrypt() async {
        guard let data = encryptedData, !passphrase.isEmpty else { return }
        do {
            let bundle = try await ConnectionBundleCodec.decode(data, passphrase: passphrase)
            try Task.checkCancellation()
            await showReview(of: bundle)
        } catch is CancellationError {
            return
        } catch {
            passphraseError = error.localizedDescription
            passphrase = ""
        }
    }

    private func showReview(of bundle: ConnectionBundle) async {
        do {
            let preview = try await IOSConnectionImportService.preview(
                of: bundle,
                fileName: fileURL.lastPathComponent,
                appState: appState
            )
            review = Review(preview: preview, selection: .defaults(for: preview))
            phase = .review
        } catch {
            phase = .failed(Self.message(for: error))
        }
    }

    private func performImport() async {
        guard let review else { return }
        let outcome = await IOSConnectionImportService.apply(
            review.plan,
            appState: appState,
            secureStore: appState.secureStore
        )
        if let failure = outcome.failure, !outcome.importedAnything {
            phase = .failed(Self.message(for: failure))
            return
        }
        onImported?(outcome.connectionsAdded + outcome.connectionsReplaced)
        dismiss()
    }

    @concurrent
    nonisolated private static func readFile(at url: URL) async -> FileContents {
        let accessing = url.startAccessingSecurityScopedResource()
        defer { if accessing { url.stopAccessingSecurityScopedResource() } }
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
}
