import Foundation
import TableProFFI
import TableProSyncTransport

// What the Sync page reads, gathered so its rules are tested without a screen.
nonisolated struct MobileSyncInputs: Equatable {
    var provider: SyncProviderTag
    var choices: PersonalSyncChoices
    var iCloudStatus: SyncStatus
    var engine: SyncStatusInfo?
    var scopes: [ScopeStatusInfo] = []
    var serverLicense: AccountServerLicense?
    var isSignedIn = false
    // This device synced with iCloud at least once, so TablePro's data may still be there after it stopped.
    var hasICloudData = false
}

// A server switch that keeps something off TablePro Sync while this device is signed in to it (core ADR 0051,
// Policies).
nonisolated enum MobileSyncServerPolicy: Equatable, Hashable {
    // No personal data at all; Team Library and the account's keys go on.
    case personalSyncOff
    case passwordsOff
    case historyOff
}

// A TablePro Sync state that needs words of its own, beyond the status row.
nonisolated enum MobileSyncServiceNotice: Equatable {
    // The organization requires TablePro Sync, and this device stays off until the person reviews its first upload.
    case awaitsUpload
    // The organization requires iCloud and this device's data is on TablePro Sync: the move back waits for the person.
    case awaitsMoveBack
    // TablePro Sync needs the account this device was signed in with.
    case signedOut
    // Past the license's grace or after a lapse, the service takes key objects only (core ADR 0051, Gates).
    case pullOnly(selfHosted: Bool)
    // A company server's license ended and its grace runs until this date (core ADR 0046).
    case grace(until: Date?)
}

nonisolated enum MobileSyncServiceStatus: Equatable {
    case upToDate
    case syncing
    case waiting
    case downloadOnly
    // This device does not hold the account's keys, so nothing personal goes up or comes down until it is approved.
    case needsApproval
    case off
    case unavailable
}

// The Sync page's rules, as the Mac's Sync pane has them (SyncPaneLayout), without license gates: the iPhone gates
// nothing on the account, and the server answers each call.
nonisolated struct MobileSyncLayout: Equatable {
    let options: [SyncProviderTag]
    let isPickerLocked: Bool
    let forcedProvider: SyncProviderTag?
    let serviceNotice: MobileSyncServiceNotice?
    // Another account or server waits for Move my data or Start empty (core ADR 0066).
    let asksNewIdentity: Bool
    let showsICloudStatus: Bool
    let serviceStatus: MobileSyncServiceStatus?
    let showsLastSynced: Bool
    let offersSyncNow: Bool
    let showsCategories: Bool
    let offersICloudDataDeletion: Bool
    let serverPolicies: [MobileSyncServerPolicy]

    static let order: [SyncProviderTag] = [.off, .icloud, .tableproSync]

    init(_ inputs: MobileSyncInputs) {
        let policies = Self.serverPolicies(inputs.scopes)
        // The server's switch takes TablePro Sync away as a new choice, and never moves a device already on it.
        let allowed = inputs.choices.providers
            .filter { $0 != .tableproSync || !policies.contains(.personalSyncOff) }
        options = Self.order.filter { allowed.contains($0) || $0 == inputs.provider }
        isPickerLocked = inputs.choices.locked
        forcedProvider = inputs.choices.locked ? inputs.choices.forced : nil
        let newIdentity = inputs.engine?.phase == .newIdentity
        asksNewIdentity = newIdentity

        switch inputs.provider {
        case .icloud:
            let pullOnly = inputs.engine?.phase == .pullOnly
            let live = !newIdentity && !pullOnly
            serviceNotice = pullOnly ? .pullOnly(selfHosted: inputs.serverLicense != nil) : nil
            showsICloudStatus = live
            serviceStatus = nil
            showsLastSynced = live
            offersSyncNow = live && inputs.iCloudStatus.isEnabled && !inputs.iCloudStatus.isSyncing
        case .tableproSync:
            let refused = policies.contains(.personalSyncOff)
            if inputs.choices.forced == .icloud {
                serviceNotice = .awaitsMoveBack
            } else if !inputs.isSignedIn {
                serviceNotice = .signedOut
            } else {
                serviceNotice = refused ? nil : Self.serviceNotice(inputs)
            }
            showsICloudStatus = false
            let live = inputs.isSignedIn && !newIdentity && !refused
            let status = live ? Self.serviceStatus(inputs.engine?.phase, problem: inputs.engine?.problem) : nil
            serviceStatus = status
            showsLastSynced = live
            offersSyncNow = live && status != .syncing
        case .off:
            let forcedService = inputs.choices.forced == .tableproSync
            serviceNotice = forcedService && inputs.isSignedIn && !policies.contains(.personalSyncOff) ? .awaitsUpload : nil
            showsICloudStatus = false
            serviceStatus = nil
            showsLastSynced = false
            offersSyncNow = false
        }

        // The categories apply before the first upload, so they show while sync is off too.
        showsCategories = !allowed.filter { $0 != .off }.isEmpty
        // The zone stays after a move until the person deletes it; never while iCloud runs here, or once it is not allowed.
        offersICloudDataDeletion = inputs.hasICloudData && inputs.provider != .icloud && allowed.contains(.icloud)
        serverPolicies = inputs.provider == .tableproSync ? policies : []
    }

    // Passwords on this server stay on this device, so the switch has nothing to turn on.
    var passwordsOffOnServer: Bool {
        serverPolicies.contains(.passwordsOff) || serverPolicies.contains(.personalSyncOff)
    }

    // `personal_sync` off holds history too, so it is the one notice then.
    static func serverPolicies(_ scopes: [ScopeStatusInfo]) -> [MobileSyncServerPolicy] {
        let personal = scopes.first { $0.scope == "personal" }
        let history = scopes.first { $0.scope == "history" }
        if personal?.personalSync == false || history?.personalSync == false {
            return [.personalSyncOff]
        }
        var policies: [MobileSyncServerPolicy] = []
        if personal?.passwordSync == false {
            policies.append(.passwordsOff)
        }
        if history?.historySync == false {
            policies.append(.historyOff)
        }
        return policies
    }

    nonisolated static func needsApproval(_ problem: String) -> Bool {
        problem.hasPrefix("keys.")
            || ["sync.locked", "sync.not_allowed", "sync.device_not_approved", "sync.device_removed"].contains(problem)
    }

    private static func serviceNotice(_ inputs: MobileSyncInputs) -> MobileSyncServiceNotice? {
        let selfHosted = inputs.serverLicense != nil
        let writable = inputs.scopes.first { $0.scope == "personal" }?.writable ?? true
        if inputs.engine?.phase == .pullOnly || !writable {
            return .pullOnly(selfHosted: selfHosted)
        }
        if let license = inputs.serverLicense, license.state == .grace {
            return .grace(until: license.graceEndsAt)
        }
        return nil
    }

    private static func serviceStatus(_ phase: SyncPhaseTag?, problem: String?) -> MobileSyncServiceStatus {
        // A keychain that has not answered yet is a wait the core retries on its own, never a failure.
        if let problem, SyncEngineRules.error(forProblem: problem) == .waitingForKeychain {
            return .waiting
        }
        if let problem, needsApproval(problem) {
            return .needsApproval
        }
        return switch phase {
        case .idle: .upToDate
        case .syncing: .syncing
        case .waiting: .waiting
        case .pullOnly: .downloadOnly
        case .off, .none: .off
        case .unavailable, .zoneRemoved, .newIdentity: .unavailable
        }
    }
}
