import SwiftUI
import TableProImport
import TableProPluginKit

struct ImportFromAWSSheet: View {
    let onFinished: (ImportOutcome) -> Void

    @Environment(\.dismiss) private var dismiss
    @StateObject private var session = AWSDiscoverySession()
    @State private var step: Step = .configure
    @State private var discoveryToken = 0

    private enum Step {
        case configure
        case discovering
        case review(ImportPreview, String?)
        case empty(String?)
        case failed(String)
    }

    var body: some View {
        Group {
            switch step {
            case .configure:
                AWSDiscoveryConfigurationStep(
                    session: session,
                    onStart: beginDiscovery,
                    onCancel: { dismiss() }
                )

            case .discovering:
                AWSDiscoveryProgressStep(session: session, onCancel: cancelDiscovery)

            case .review(let preview, let notice):
                ImportReviewStep(
                    title: String(localized: "Databases found in AWS"),
                    banner: notice.map(ImportReviewBanner.notice),
                    preview: preview,
                    onBack: { step = .configure },
                    onFinished: onFinished
                )

            case .empty(let notice):
                messageView(emptyMessage, symbol: "magnifyingglass", notice: notice)

            case .failed(let message):
                messageView(message, symbol: "exclamationmark.triangle", notice: nil)
            }
        }
        .importSheetFrame()
        .task(id: discoveryToken) {
            guard isDiscovering else { return }
            await session.run()
            guard !Task.isCancelled, isDiscovering else { return }
            await finishDiscovery()
        }
        .onAppear { preselectProfileRegion() }
    }

    private func messageView(_ message: String, symbol: String, notice: String?) -> some View {
        VStack(spacing: 12) {
            Spacer()
            Image(systemName: symbol)
                .font(.title)
                .foregroundStyle(.secondary)
            Text(verbatim: message)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal)
            if let notice {
                Text(verbatim: notice)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .lineLimit(3)
                    .padding(.horizontal)
                    .help(notice)
            }
            Spacer()
            HStack {
                Button(String(localized: "Back")) { step = .configure }
                    .keyboardShortcut(.cancelAction)
                Spacer()
                Button(String(localized: "Done")) { dismiss() }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
            }
            .padding(12)
        }
    }

    private var emptyMessage: String {
        let regions = session.selectedRegionIds
            .map { AWSRegionCatalog.displayName(for: $0) }
            .formatted(.list(type: .and))
        return String(
            format: String(localized: "No RDS instances or Aurora clusters in %@."),
            regions
        )
    }

    private func preselectProfileRegion() {
        guard session.selectedRegionIds.isEmpty else { return }
        if session.profileName.isEmpty, let first = session.availableProfiles.first {
            session.profileName = first
        }
        guard let region = session.defaultRegionForProfile() else { return }
        let canonical = AWSPartition.canonicalRegion(region)
        guard AWSRegionCatalog.isWellFormed(canonical) else { return }
        session.selectedRegionIds = [canonical]
    }

    private var readerEndpointHosts: Set<String> {
        Set(
            session.importableDatabases
                .filter { $0.kind == .clusterReader }
                .compactMap { $0.host?.lowercased() }
        )
    }

    private var isDiscovering: Bool {
        if case .discovering = step { return true }
        return false
    }

    private func beginDiscovery() {
        step = .discovering
        discoveryToken += 1
    }

    private func cancelDiscovery() {
        step = .configure
        session.abandonRun()
        discoveryToken += 1
    }

    private func finishDiscovery() async {
        guard session.credentialFailure == nil else {
            step = .configure
            return
        }
        let notice = notice()
        do {
            let preview = try await makePreview()
            guard !Task.isCancelled, isDiscovering else { return }
            guard !preview.connections.isEmpty else {
                step = .empty(notice)
                return
            }
            step = .review(preview, notice)
        } catch {
            guard !Task.isCancelled, isDiscovering else { return }
            step = .failed(ImportReviewLoader.message(for: error))
        }
    }

    private func makePreview() async throws -> ImportPreview {
        let existing = ConnectionStorage.shared.loadConnections()
        let connections = RDSConnectionBuilder.exportables(
            for: session.importableDatabases,
            authentication: session.authentication,
            existingNames: existing.map(\.name)
        )
        let adopted = RDSDiscoveryReconciler.adoptingExistingIdentity(
            connections,
            existing: existing.map {
                RDSDiscoveryReconciler.ExistingEndpoint(
                    host: $0.host,
                    port: $0.port,
                    database: $0.database,
                    username: $0.username
                )
            }
        )
        let collected = try RDSDiscoveryReconciler.collected(for: adopted, deselectedHosts: readerEndpointHosts)
        return try await ImportReviewLoader.preview(of: collected)
    }

    private func notice() -> String? {
        var notices: [String] = []
        if !session.failedRegions.isEmpty {
            notices.append(failedRegionSummary)
        }
        let engines = session.unsupportedEngines
        if !engines.isEmpty {
            notices.append(
                String(
                    format: String(localized: "Skipped %@: TablePro has no driver for that engine."),
                    engines.formatted(.list(type: .and))
                )
            )
        }
        let endpointless = session.endpointlessIdentifiers
        if !endpointless.isEmpty {
            notices.append(
                String(
                    format: String(localized: "Skipped %@: no endpoint yet."),
                    endpointless.formatted(.list(type: .and))
                )
            )
        }
        return notices.isEmpty ? nil : notices.joined(separator: " ")
    }

    private var failedRegionSummary: String {
        let failures = session.failedRegions
        guard failures.count > 1 else {
            guard let failure = failures.first else { return "" }
            return "\(AWSRegionCatalog.displayName(for: failure.region)): \(failure.message)"
        }
        return String(
            format: String(localized: "%d regions could not be searched."),
            failures.count
        )
    }
}
