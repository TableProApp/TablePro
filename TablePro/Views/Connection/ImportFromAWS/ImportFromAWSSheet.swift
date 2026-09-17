import SwiftUI
import TableProImport
import TableProPluginKit

struct ImportFromAWSSheet: View {
    var onImported: ((Int) -> Void)?

    @Environment(\.dismiss) private var dismiss
    @StateObject private var session = AWSDiscoverySession()
    @State private var step: Step = .configure
    @State private var discoveryToken = 0

    private enum Step {
        case configure
        case discovering
        case preview(ConnectionImportPreview, String?)
        case empty(String?)
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

            case .preview(let preview, let notice):
                AWSDiscoveryPreviewStep(
                    preview: preview,
                    notice: notice,
                    deselectedHosts: readerEndpointHosts,
                    onBack: { step = .configure },
                    onImported: onImported
                )

            case .empty(let notice):
                emptyView(notice)
            }
        }
        .frame(width: 520, height: 440)
        .task(id: discoveryToken) {
            guard isDiscovering else { return }
            await session.run()
            guard !Task.isCancelled, isDiscovering else { return }
            finishDiscovery()
        }
        .onAppear { preselectProfileRegion() }
    }

    private func emptyView(_ notice: String?) -> some View {
        VStack(spacing: 12) {
            Spacer()
            Image(systemName: "magnifyingglass")
                .font(.title)
                .foregroundStyle(.secondary)
            Text(verbatim: emptyMessage)
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

    private func finishDiscovery() {
        guard session.credentialFailure == nil else {
            step = .configure
            return
        }
        let notice = notice()
        let preview = makePreview()
        guard !preview.items.isEmpty else {
            step = .empty(notice)
            return
        }
        step = .preview(preview, notice)
    }

    private func makePreview() -> ConnectionImportPreview {
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
        let analyzed = ConnectionExportService.analyzeImport(
            RDSDiscoveryReconciler.envelope(for: adopted)
        )
        return RDSDiscoveryReconciler.markingMissingDrivers(analyzed) { typeId in
            let type = DatabaseType(rawValue: typeId)
            guard case .notInstalled = PluginManager.shared.driverUnavailability(for: type) else { return nil }
            return PluginManager.registryDisplayName(of: type)
        }
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
