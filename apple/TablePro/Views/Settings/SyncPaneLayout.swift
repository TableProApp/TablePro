import Foundation
import TableProFFI
import TableProSyncTransport

// What the Sync pane reads, gathered so the pane's rules are tested without a window.
struct SyncPaneInputs {
    var provider: SyncProviderSetting
    var choices: PersonalSyncChoices
    var iCloudAccess: ProFeatureAccess
    var serviceAccess: ProFeatureAccess
    var iCloudStatus: SyncStatus
    var engine: SyncStatusInfo?
    var serverLicense: AccountServerLicense?
    var offersICloudDataDeletion = false
    // The scopes TablePro Sync read last, with the server's switches.
    var scopes: [ScopeStatusInfo] = []
}

// A server switch that keeps something off TablePro Sync while this Mac is signed in to it (core ADR 0051, Policies).
enum SyncServerPolicy: Equatable, Hashable {
    // No personal data at all; Team Library and the account's keys go on.
    case personalSyncOff
    case passwordsOff
    case historyOff
}

// Why the organization's profile holds the picker, when it does (core ADR 0055, PersonalSyncProvider).
enum SyncManagedNote: Equatable {
    case forced(SyncProviderSetting)
    case noProvider
}

// A TablePro Sync state that needs words of its own, beyond the status row.
enum SyncServiceNotice: Equatable {
    // The profile requires TablePro Sync, and this Mac stays off until the person reviews its first upload (core ADR
    // 0055, PersonalSyncProvider).
    case awaitsUpload
    // The profile requires iCloud and this Mac's data is on TablePro Sync: the move back waits for the person, who
    // confirms what it deletes on iCloud (core ADR 0054, Back to iCloud).
    case awaitsMoveBack
    // Past the license's grace or after a lapse, the service takes key objects only (core ADR 0051, Gates).
    case pullOnly(selfHosted: Bool)
    // A company server's license ended and its grace runs until this date (core ADR 0046).
    case grace(until: Date?)
}

enum SyncServiceStatus: Equatable {
    case upToDate
    case syncing
    case waiting
    case downloadOnly
    case off
    case unavailable
}

struct SyncPaneLayout: Equatable {
    let options: [SyncProviderSetting]
    let isPickerLocked: Bool
    let managedNote: SyncManagedNote?
    let licenseGate: ProFeature?
    // An iCloud blocker, stated at length in place of the status row.
    let iCloudNotice: SyncNotice?
    let serviceNotice: SyncServiceNotice?
    // Another account or server waits for Move my data or Start empty, on either provider (core ADR 0066).
    let asksNewIdentity: Bool
    let showsICloudStatus: Bool
    let serviceStatus: SyncServiceStatus?
    let showsLastSynced: Bool
    let offersSyncNow: Bool
    let showsCategories: Bool
    let offersICloudDataDeletion: Bool
    let serverPolicies: [SyncServerPolicy]

    init(_ inputs: SyncPaneInputs) {
        let policies = Self.serverPolicies(inputs.scopes)
        // The server's switch takes TablePro Sync away as a new choice, and never moves a Mac already on it.
        let allowed = inputs.choices.providers.map { SyncProviderSetting($0) }
            .filter { $0 != .tableproSync || !policies.contains(.personalSyncOff) }
        options = SyncProviderSetting.allCases.filter { allowed.contains($0) || $0 == inputs.provider }
        isPickerLocked = inputs.choices.locked
        managedNote = Self.managedNote(inputs.choices)
        let newIdentity = inputs.engine?.phase == .newIdentity
        asksNewIdentity = newIdentity

        let iCloudAllowed = allowed.contains(.iCloud)
        let serviceAllowed = allowed.contains(.tableproSync)
        let iCloudLicensed = inputs.iCloudAccess == .available
        // Past grace the service still serves pulls, so the provider stays and says so.
        let serviceLicensed = inputs.serviceAccess == .available || inputs.serviceAccess == .expired

        switch inputs.provider {
        case .iCloud:
            // The coordinator reads both engine phases as an unexpected error; they have states of their own here.
            let presentation = SyncStatusPresentation(status: inputs.iCloudStatus)
            let pullOnly = inputs.engine?.phase == .pullOnly
            let live = iCloudLicensed && iCloudAllowed && !newIdentity && !pullOnly
            licenseGate = iCloudLicensed || !iCloudAllowed ? nil : .iCloudSync
            iCloudNotice = live ? presentation.notice : nil
            serviceNotice = pullOnly ? .pullOnly(selfHosted: inputs.serverLicense != nil) : nil
            showsICloudStatus = live && presentation.notice == nil
            serviceStatus = nil
            showsLastSynced = live
            offersSyncNow = live && presentation.offersSyncNow
        case .tableproSync:
            // The stored provider changes only once a move returned, so a Mac on TablePro Sync has moved.
            let refused = policies.contains(.personalSyncOff)
            licenseGate = inputs.serviceAccess == .available ? nil : .serviceSync
            iCloudNotice = nil
            serviceNotice = inputs.choices.forced == .icloud
                ? .awaitsMoveBack
                : (refused || !serviceLicensed ? nil : Self.serviceNotice(inputs))
            showsICloudStatus = false
            let live = serviceLicensed && !newIdentity && !refused
            let status = live ? Self.serviceStatus(inputs.engine?.phase, problem: inputs.engine?.problem) : nil
            serviceStatus = status
            showsLastSynced = live
            offersSyncNow = live && status != .syncing
        case .off:
            let forcedService = inputs.choices.forced == .tableproSync
            // A forced TablePro Sync on a Mac that is not signed in leaves sync off, and the gate says why.
            licenseGate = forcedService && inputs.serviceAccess != .available ? .serviceSync : nil
            iCloudNotice = nil
            serviceNotice = forcedService && inputs.serviceAccess == .available && !policies.contains(.personalSyncOff)
                ? .awaitsUpload
                : nil
            showsICloudStatus = false
            serviceStatus = nil
            showsLastSynced = false
            offersSyncNow = false
        }

        // The categories apply before the first upload, so they show while sync is off too.
        showsCategories = (iCloudAllowed && iCloudLicensed) || (serviceAllowed && serviceLicensed)
        offersICloudDataDeletion = inputs.offersICloudDataDeletion
        serverPolicies = inputs.provider == .tableproSync ? policies : []
    }

    // Passwords on this server stay on this Mac, so the switch has nothing to turn on.
    var passwordsOffOnServer: Bool {
        serverPolicies.contains(.passwordsOff) || serverPolicies.contains(.personalSyncOff)
    }

    // `personal_sync` off holds history too, so it is the one notice then.
    static func serverPolicies(_ scopes: [ScopeStatusInfo]) -> [SyncServerPolicy] {
        let personal = scopes.first { $0.scope == "personal" }
        let history = scopes.first { $0.scope == "history" }
        if personal?.personalSync == false || history?.personalSync == false {
            return [.personalSyncOff]
        }
        var policies: [SyncServerPolicy] = []
        if personal?.passwordSync == false {
            policies.append(.passwordsOff)
        }
        if history?.historySync == false {
            policies.append(.historyOff)
        }
        return policies
    }

    private static func managedNote(_ choices: PersonalSyncChoices) -> SyncManagedNote? {
        guard choices.locked else { return nil }
        guard let forced = choices.forced else { return .noProvider }
        return .forced(SyncProviderSetting(forced))
    }

    private static func serviceNotice(_ inputs: SyncPaneInputs) -> SyncServiceNotice? {
        let selfHosted = inputs.serverLicense != nil
        let writable = inputs.scopes.first { $0.scope == "personal" }?.writable ?? true
        if inputs.engine?.phase == .pullOnly || inputs.serviceAccess == .expired || !writable {
            return .pullOnly(selfHosted: selfHosted)
        }
        if let license = inputs.serverLicense, license.state == .grace {
            return .grace(until: license.graceEndsAt)
        }
        return nil
    }

    private static func serviceStatus(_ phase: SyncPhaseTag?, problem: String?) -> SyncServiceStatus {
        // A keychain that has not answered yet is a wait the core retries on its own, never a failure.
        if let problem, SyncEngineRules.error(forProblem: problem) == .waitingForKeychain {
            return .waiting
        }
        switch phase {
        case .idle: .upToDate
        case .syncing: .syncing
        case .waiting: .waiting
        case .pullOnly: .downloadOnly
        case .off, .none: .off
        case .unavailable, .zoneRemoved, .newIdentity: .unavailable
        }
    }
}
