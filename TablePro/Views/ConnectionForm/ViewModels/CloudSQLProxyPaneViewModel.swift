//
//  CloudSQLProxyPaneViewModel.swift
//  TablePro
//

import Combine
import Foundation
import os

@MainActor
final class CloudSQLProxyPaneViewModel: ObservableObject {
    nonisolated private static let logger = Logger(subsystem: "com.TablePro", category: "CloudSQLProxyPane")

    @Published var state = CloudSQLProxyFormState()

    @Published var coordinator: WeakCoordinatorRef?

    @Published var resolvedBinaryPath: String?
    @Published var didResolveBinary: Bool = false
    @Published var downloadedVersion: String?
    @Published var isDownloading: Bool = false
    @Published var downloadError: String?

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

    func resolveBinary() {
        Task {
            let found = await Task.detached { CLIExecutableFinder.findExecutable("cloud-sql-proxy") }.value
            if let found {
                resolvedBinaryPath = found
            } else {
                resolvedBinaryPath = await CloudSQLProxyBinaryManager.shared.isInstalled
                    ? CloudSQLProxyBinaryManager.shared.binaryExecutablePath
                    : nil
            }
            downloadedVersion = await CloudSQLProxyBinaryManager.shared.installedVersion()
            didResolveBinary = true
        }
    }

    func downloadBinary() {
        guard !isDownloading else { return }
        isDownloading = true
        downloadError = nil
        Task {
            defer { isDownloading = false }
            do {
                let path = try await CloudSQLProxyBinaryManager.shared.ensureBinary()
                resolvedBinaryPath = path
                downloadedVersion = await CloudSQLProxyBinaryManager.shared.installedVersion()
                didResolveBinary = true
                Self.logger.info("cloud-sql-proxy ready at \(path, privacy: .private(mask: .hash))")
            } catch {
                downloadError = error.localizedDescription
                Self.logger.error("cloud-sql-proxy download failed: \(error.publicLogShape, privacy: .public)")
            }
        }
    }
}
