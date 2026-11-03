//
//  CloudSQLProxyPaneViewModel.swift
//  TablePro
//

import Combine
import Foundation

@MainActor
final class CloudSQLProxyPaneViewModel: ObservableObject {
    @Published var state = CloudSQLProxyFormState()

    @Published var coordinator: WeakCoordinatorRef?

    @Published var resolvedBinaryPath: String?
    @Published var didResolveBinary: Bool = false

    let download: CloudSQLProxyDownload
    private var downloadObservation: AnyCancellable?
    private var wasDownloading = false

    init(download: CloudSQLProxyDownload = .shared) {
        self.download = download
        // A connect or a Test Connection can download the binary too, so this follows the shared state.
        downloadObservation = download.$phase.sink { [weak self] phase in
            guard let self else { return }
            objectWillChange.send()
            if phase == .idle, wasDownloading {
                resolveBinary()
            }
            wasDownloading = phase.isDownloading
        }
    }

    var downloadPhase: CloudSQLProxyDownload.Phase { download.phase }

    var isDownloading: Bool { download.phase.isDownloading }

    var validationIssues: [String] {
        guard state.enabled else { return [] }
        var issues: [String] = []

        if !state.buildConfig().isValid {
            issues.append(String(localized: "Instance connection name must be project:region:instance"))
        }

        if !state.automaticPort {
            let portIsValid = Int(state.localPort).map { (1...65_535).contains($0) } ?? false
            if !portIsValid {
                issues.append(String(localized: "Local port must be between 1 and 65535"))
            }
        }

        if state.authMode == .serviceAccountKey,
           state.serviceAccountKeyJSON.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            issues.append(String(localized: "A service account key is required"))
        }

        return issues
    }

    func load(from connection: DatabaseConnection, storage: ConnectionStorage) {
        state.load(from: connection)
        state.serviceAccountKeyJSON = storage.loadCloudSQLProxyServiceAccountKey(for: connection.id) ?? ""
        resolveBinary()
    }

    func save(to connectionId: UUID, storage: ConnectionStorage) {
        guard state.enabled, state.authMode == .serviceAccountKey,
              !state.serviceAccountKeyJSON.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            storage.deleteCloudSQLProxyServiceAccountKey(for: connectionId)
            return
        }
        storage.saveCloudSQLProxyServiceAccountKey(state.serviceAccountKeyJSON, for: connectionId)
    }

    internal var binaryNotFoundMessage: String {
        String(
            localized: "cloud-sql-proxy not found. Install it with “brew install cloud-sql-proxy”, download it above, or choose the binary."
        )
    }

    func resolveBinary() {
        let binaryManager = download.binaryManager
        Task {
            let found = await Task.detached { CLIExecutableFinder.findExecutable("cloud-sql-proxy") }.value
            if let found {
                resolvedBinaryPath = found
            } else {
                resolvedBinaryPath = await binaryManager.installedBinaryIsCurrent()
                    ? binaryManager.binaryExecutablePath
                    : nil
            }
            didResolveBinary = true
        }
    }

    func downloadBinary() {
        download.start()
    }

    func cancelDownload() {
        download.cancel()
    }
}
