import Combine
import Foundation
import os
import TableProPluginKit

@MainActor
final class AWSDiscoverySession: ObservableObject {
    enum RegionProgress: Equatable, Sendable {
        case pending
        case loading
        case loaded(Int)
        case failed(String)
    }

    struct CredentialFailure: Equatable, Sendable {
        let message: String
        let canSignIn: Bool
    }

    static let maximumConcurrentRegions = 4

    private static let logger = Logger(subsystem: "com.TablePro", category: "AWSDiscovery")

    @Published var profileName: String {
        didSet {
            guard profileName != oldValue else { return }
            refreshProfileMetadata()
        }
    }

    @Published var selectedRegionIds: [String] = []
    @Published var authenticationMode: AWSDiscoveryAuthentication.Mode = .iam
    @Published private(set) var profileKind: AWSProfileKind = .unknown

    @Published private(set) var isRunning = false
    @Published private(set) var isSigningIn = false
    @Published private(set) var regionProgress: [String: RegionProgress] = [:]
    @Published private(set) var databases: [DiscoveredDatabase] = []
    @Published private(set) var credentialFailure: CredentialFailure?

    /// A cancelled run cannot be interrupted while `credential_process` blocks in its own
    /// process, so the UI is released by generation and the late completion discards itself.
    @Published private var runGeneration = 0

    init(profileName: String = "") {
        self.profileName = profileName
        refreshProfileMetadata()
    }

    private func refreshProfileMetadata() {
        let profile = trimmedProfileName
        profileKind = profile.isEmpty ? .unknown : AWSCredentialResolver.profileKind(named: profile)
        credentialFailure = nil
    }

    var availableProfiles: [String] {
        AWSConfigFile.discoverProfiles(
            configContents: AWSConfigFile.readFile(AWSConfigFile.defaultConfigPath),
            credentialsContents: AWSConfigFile.readFile(AWSConfigFile.defaultCredentialsPath)
        )
    }

    var canStart: Bool {
        !trimmedProfileName.isEmpty && !selectedRegionIds.isEmpty && !isRunning
    }

    var importableDatabases: [DiscoveredDatabase] {
        databases.filter { $0.isImportable && RDSEngineCatalog.databaseType(forEngine: $0.engine) != nil }
    }

    var unsupportedEngines: [String] {
        let engines = databases
            .filter { RDSEngineCatalog.databaseType(forEngine: $0.engine) == nil }
            .map(\.engine)
        return Array(Set(engines)).sorted()
    }

    var endpointlessIdentifiers: [String] {
        databases
            .filter { !$0.isImportable && RDSEngineCatalog.databaseType(forEngine: $0.engine) != nil }
            .map(\.identifier)
            .sorted()
    }

    var failedRegions: [(region: String, message: String)] {
        selectedRegionIds.compactMap { region in
            guard case .failed(let message) = regionProgress[region] else { return nil }
            return (region, message)
        }
    }

    var authentication: AWSDiscoveryAuthentication {
        AWSDiscoveryAuthentication(
            mode: authenticationMode,
            awsAuthValue: profileKind == .singleSignOn ? "sso" : "profile",
            profileName: trimmedProfileName
        )
    }

    func defaultRegionForProfile() -> String? {
        guard !trimmedProfileName.isEmpty else { return nil }
        return AWSCredentialResolver.profileRegion(named: trimmedProfileName)
    }

    func run() async {
        guard canStart else { return }
        let regions = selectedRegionIds
        let profile = trimmedProfileName

        runGeneration += 1
        let generation = runGeneration
        isRunning = true
        credentialFailure = nil
        databases = []
        regionProgress = Dictionary(uniqueKeysWithValues: regions.map { ($0, RegionProgress.pending) })
        defer {
            if generation == runGeneration {
                isRunning = false
            }
        }

        await run(profile: profile, regions: regions, generation: generation)
    }

    /// Releases the sheet from a run whose credential helper may still be blocking, so Continue
    /// comes back immediately and whatever the abandoned run produces is discarded.
    func abandonRun() {
        runGeneration += 1
        isRunning = false
        regionProgress = [:]
    }

    func signIn() async {
        guard !isSigningIn else { return }
        let profile = trimmedProfileName
        isSigningIn = true
        defer { isSigningIn = false }
        do {
            try await AWSSSOLoginService.signIn(profileName: profile)
            credentialFailure = nil
        } catch {
            credentialFailure = CredentialFailure(message: error.localizedDescription, canSignIn: true)
        }
    }

    private var trimmedProfileName: String {
        profileName.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func run(profile: String, regions: [String], generation: Int) async {
        let credentials: AWSCredentials
        do {
            credentials = try await AWSCredentialResolver.resolveProfile(named: profile)
        } catch {
            guard generation == runGeneration else { return }
            Self.logger.error("AWS discovery could not resolve credentials for the selected profile")
            credentialFailure = CredentialFailure(
                message: error.localizedDescription,
                canSignIn: AWSSSOLoginService.isSSOExpired(error)
            )
            return
        }

        guard !Task.isCancelled, generation == runGeneration else { return }

        let client = RDSDiscoveryClient(credentials: credentials)
        var collected: [DiscoveredDatabase] = []
        var credentialFailures: [String] = []

        await withTaskGroup(of: RegionOutcome.self) { group in
            var next = 0
            let firstBatch = min(Self.maximumConcurrentRegions, regions.count)
            while next < firstBatch {
                let region = regions[next]
                regionProgress[region] = .loading
                group.addTask { await Self.discover(region: region, client: client) }
                next += 1
            }

            for await outcome in group {
                if let failure = outcome.failure {
                    if !failure.isCancellation, generation == runGeneration {
                        regionProgress[outcome.region] = .failed(failure.message)
                    }
                    if failure.isCredentialFailure {
                        credentialFailures.append(failure.message)
                    }
                } else {
                    collected.append(contentsOf: outcome.databases)
                    if generation == runGeneration {
                        regionProgress[outcome.region] = .loaded(outcome.databases.count)
                    }
                }

                guard !Task.isCancelled, next < regions.count else { continue }
                let region = regions[next]
                regionProgress[region] = .loading
                group.addTask { await Self.discover(region: region, client: client) }
                next += 1
            }
        }

        guard generation == runGeneration else { return }

        /// One partition's credentials are invalid in another, so a credential failure is only the
        /// run's failure when every region reported one; otherwise it stays on its own row.
        if credentialFailures.count == regions.count, let message = credentialFailures.first {
            credentialFailure = CredentialFailure(
                message: message,
                canSignIn: profileKind == .singleSignOn || profileKind == .assumeRole
            )
        }

        databases = collected.sorted { lhs, rhs in
            if lhs.region != rhs.region { return lhs.region < rhs.region }
            if lhs.identifier != rhs.identifier { return lhs.identifier < rhs.identifier }
            return lhs.kind.rawValue < rhs.kind.rawValue
        }
    }

    private struct RegionFailure: Sendable, Equatable {
        let message: String
        let isCredentialFailure: Bool
        let isCancellation: Bool
    }

    private struct RegionOutcome: Sendable {
        let region: String
        let databases: [DiscoveredDatabase]
        let failure: RegionFailure?
    }

    private static func discover(region: String, client: RDSDiscoveryClient) async -> RegionOutcome {
        do {
            async let instances = client.describeInstances(region: region)
            async let clusters = client.describeClusters(region: region)
            let databases = try await RDSDiscoveryPlan.flatten(
                region: region,
                instances: instances,
                clusters: clusters
            )
            return RegionOutcome(region: region, databases: databases, failure: nil)
        } catch is CancellationError {
            return RegionOutcome(
                region: region,
                databases: [],
                failure: RegionFailure(message: "", isCredentialFailure: false, isCancellation: true)
            )
        } catch {
            let discoveryError = error as? RDSDiscoveryError
            return RegionOutcome(
                region: region,
                databases: [],
                failure: RegionFailure(
                    message: error.localizedDescription,
                    isCredentialFailure: discoveryError?.isCredentialFailure ?? false,
                    isCancellation: false
                )
            )
        }
    }
}
