//
//  CloudSQLProxyDownload.swift
//  TablePro
//

import Combine
import Foundation
import os
import TableProPluginKit

@MainActor
final class CloudSQLProxyDownload: ObservableObject {
    enum Phase: Equatable {
        case idle
        case downloading(fraction: Double?)
        case failed(String)

        var isDownloading: Bool {
            if case .downloading = self { return true }
            return false
        }
    }

    static let shared = CloudSQLProxyDownload(binaryManager: .shared)
    nonisolated private static let logger = Logger(subsystem: "com.TablePro", category: "CloudSQLProxyDownload")

    let binaryManager: CloudSQLProxyBinaryManager
    @Published private(set) var phase: Phase = .idle

    private var running: (id: UUID, task: Task<String, Error>)?
    private var waiters: Set<UUID> = []

    init(binaryManager: CloudSQLProxyBinaryManager) {
        self.binaryManager = binaryManager
    }

    func start() {
        guard running == nil else { return }
        Task { _ = try? await ensureBinary() }
    }

    func cancel() {
        guard let running else { return }
        running.task.cancel()
        self.running = nil
        phase = .idle
    }

    // Every caller shares one download. It stops when `cancel()` is called or when every caller waiting on it is cancelled.
    func ensureBinary() async throws -> String {
        if await binaryManager.installedBinaryIsCurrent() {
            return binaryManager.binaryExecutablePath
        }

        let reportStage = CloudSQLProxyManager.connectStageReporter
        reportStage?(.custom(String(localized: "Downloading Cloud SQL Auth Proxy")))
        defer { reportStage?(.resolvingTunnel) }

        let task = running?.task ?? startDownload()
        let token = UUID()
        waiters.insert(token)
        defer { waiters.remove(token) }

        return try await withTaskCancellationHandler {
            let path = try await task.value
            try Task.checkCancellation()
            return path
        } onCancel: {
            Task { @MainActor in self.abandon(token, of: task) }
        }
    }

    private func startDownload() -> Task<String, Error> {
        let id = UUID()
        let binaryManager = binaryManager
        phase = .downloading(fraction: nil)
        let task = Task { () async throws -> String in
            do {
                let path = try await binaryManager.ensureBinary { fraction in
                    await self.report(fraction, for: id)
                }
                finish(id, phase: .idle)
                return path
            } catch is CancellationError {
                finish(id, phase: .idle)
                throw CancellationError()
            } catch {
                Self.logger.error("cloud-sql-proxy download failed: \(error.publicLogShape, privacy: .public)")
                finish(id, phase: .failed(error.localizedDescription))
                throw error
            }
        }
        running = (id, task)
        return task
    }

    private func report(_ fraction: Double, for id: UUID) {
        guard running?.id == id, case .downloading = phase else { return }
        phase = .downloading(fraction: fraction)
    }

    private func finish(_ id: UUID, phase: Phase) {
        guard running?.id == id else { return }
        running = nil
        self.phase = phase
    }

    private func abandon(_ token: UUID, of task: Task<String, Error>) {
        waiters.remove(token)
        guard waiters.isEmpty, let running, running.task == task else { return }
        cancel()
    }
}
