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
}

// Why the organization's profile holds the picker, when it does (core ADR 0055, PersonalSyncProvider).
enum SyncManagedNote: Equatable {
    case forced(SyncProviderSetting)
    case noProvider
}

// A TablePro Sync state that needs words of its own, beyond the status row.
enum SyncServiceNotice: Equatable {
    // TablePro Sync is chosen and nothing has gone up yet: the profile chose it, or a move did not finish.
    case awaitsUpload(forced: Bool)
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

    init(_ inputs: SyncPaneInputs) {
        let allowed = inputs.choices.providers.map { SyncProviderSetting($0) }
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
            let presentation = SyncStatusPresentation(status: inputs.iCloudStatus)
            let live = iCloudLicensed && iCloudAllowed && !newIdentity
            licenseGate = iCloudLicensed || !iCloudAllowed ? nil : .iCloudSync
            iCloudNotice = live ? presentation.notice : nil
            serviceNotice = nil
            showsICloudStatus = live && presentation.notice == nil
            serviceStatus = nil
            showsLastSynced = live
            offersSyncNow = live && presentation.offersSyncNow
        case .tableproSync:
            let movedHere = inputs.engine?.provider == .tableproSync
            licenseGate = inputs.serviceAccess == .available ? nil : .serviceSync
            iCloudNotice = nil
            serviceNotice = Self.serviceNotice(inputs, movedHere: movedHere, licensed: serviceLicensed)
            showsICloudStatus = false
            let live = movedHere && serviceLicensed && !newIdentity
            let status = live ? Self.serviceStatus(inputs.engine?.phase) : nil
            serviceStatus = status
            showsLastSynced = live
            offersSyncNow = live && status != .syncing
        case .off:
            licenseGate = nil
            iCloudNotice = nil
            serviceNotice = nil
            showsICloudStatus = false
            serviceStatus = nil
            showsLastSynced = false
            offersSyncNow = false
        }

        // The categories apply before the first upload, so they show while sync is off too.
        showsCategories = (iCloudAllowed && iCloudLicensed) || (serviceAllowed && serviceLicensed)
        offersICloudDataDeletion = inputs.offersICloudDataDeletion
    }

    private static func managedNote(_ choices: PersonalSyncChoices) -> SyncManagedNote? {
        guard choices.locked else { return nil }
        guard let forced = choices.forced else { return .noProvider }
        return .forced(SyncProviderSetting(forced))
    }

    private static func serviceNotice(_ inputs: SyncPaneInputs, movedHere: Bool, licensed: Bool) -> SyncServiceNotice? {
        guard licensed else { return nil }
        guard movedHere else {
            // Until the person signs in to a server that grants TablePro Sync, the license gate says what to do.
            guard inputs.serviceAccess == .available else { return nil }
            return .awaitsUpload(forced: inputs.choices.forced == .tableproSync)
        }
        let selfHosted = inputs.serverLicense != nil
        if inputs.engine?.phase == .pullOnly || inputs.serviceAccess == .expired {
            return .pullOnly(selfHosted: selfHosted)
        }
        if let license = inputs.serverLicense, license.state == .grace {
            return .grace(until: license.graceEndsAt)
        }
        return nil
    }

    private static func serviceStatus(_ phase: SyncPhaseTag?) -> SyncServiceStatus {
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
