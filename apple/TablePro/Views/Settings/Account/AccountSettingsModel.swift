//
//  AccountSettingsModel.swift
//  TablePro
//

import Combine
import Foundation

internal struct AccountRemote<Value: Equatable>: Equatable {
    var value: Value?
    var isLoading = false
    var failure: String?
}

internal struct AccountActionFailure: Equatable, Identifiable {
    let title: String
    let message: String

    var id: String { title + message }
}

@MainActor
internal final class AccountSettingsModel: ObservableObject {
    enum Activity: Equatable {
        case signingIn
        case signingOut
        case checking
        case removing(String)
        case importing
        case usingKey
    }

    @Published private(set) var profile = AccountRemote<AccountProfile>()
    @Published private(set) var devices = AccountRemote<[AccountDevice]>()
    @Published private(set) var activity: Activity?
    @Published private(set) var signInFailure: String?
    @Published var actionFailure: AccountActionFailure?
    @Published var presentsDeviceLimit = false
    @Published var presentsLicenseKey = false
    // Read once when the sheet opens, not on every render: it comes from the Keychain.
    @Published private(set) var licenseKeyPrefill: String?
    @Published var presentsOfflineImporter = false

    let services: AccountServices
    private let now: () -> Date
    private var stateObserver: AnyCancellable?
    private var loadedSignedIn: Bool?

    init(services: AccountServices, now: @escaping () -> Date = { Date() }) {
        self.services = services
        self.now = now
        stateObserver = services.access.$state
            .dropFirst()
            .sink { [weak self] state in
                guard let self else { return }
                objectWillChange.send()
                if let loadedSignedIn, state.isSignedIn != loadedSignedIn {
                    Task { await self.reload() }
                }
            }
    }

    var access: FeatureAccess {
        services.access
    }

    var content: AccountSettingsContent {
        AccountSettingsContent.make(
            state: services.access.state,
            profile: profile.value,
            devices: devices.value,
            hasLegacyLicense: services.access.state.legacy != nil,
            machineID: services.machineID,
            configuration: services.configuration,
            now: now()
        )
    }

    var isBusy: Bool {
        activity != nil
    }

    // Keeps what it loaded before when a load fails; a sign-in or sign-out drops it first.
    func reload() async {
        let isSignedIn = services.access.state.isSignedIn
        if isSignedIn != loadedSignedIn {
            forgetLoaded()
            loadedSignedIn = isSignedIn
        }
        guard isSignedIn else { return }
        async let profileLoad: Void = loadProfile()
        async let devicesLoad: Void = loadDevices()
        _ = await (profileLoad, devicesLoad)
    }

    func loadProfile() async {
        if profile.value == nil {
            profile.isLoading = true
        }
        do throws(AccountError) {
            profile = AccountRemote(value: try await services.fetchProfile())
        } catch {
            profile.isLoading = false
            profile.failure = error.friendlyDescription ?? String(localized: "Could not load your teams.")
        }
    }

    func loadDevices() async {
        if devices.value == nil {
            devices.isLoading = true
        }
        do throws(AccountError) {
            devices = AccountRemote(value: try await services.fetchDevices())
        } catch {
            devices.isLoading = false
            devices.failure = error.friendlyDescription ?? String(localized: "Could not load your devices.")
        }
    }

    func signIn(using authenticator: some WebAuthenticating) async {
        signInFailure = nil
        activity = .signingIn
        defer { activity = nil }
        do throws(AccountError) {
            try await services.signIn(using: authenticator)
        } catch {
            signInFailure = error.friendlyDescription
            return
        }
        presentDeviceLimitIfReached()
    }

    func signOut() async {
        activity = .signingOut
        defer { activity = nil }
        await services.signOut()
    }

    func checkNow() async {
        activity = .checking
        defer { activity = nil }
        await services.checkNow()
        await reload()
    }

    func removeDevice(_ device: AccountSettingsContent.DeviceRow) async {
        activity = .removing(device.id)
        defer { activity = nil }
        do throws(AccountError) {
            try await services.removeDevice(device.id)
        } catch {
            actionFailure = error.deviceRemovalDescription.map {
                AccountActionFailure(
                    title: String(format: String(localized: "Could not remove “%@”"), device.name),
                    message: $0
                )
            }
        }
        await loadDevices()
    }

    func importOfflineFile(at url: URL) async {
        activity = .importing
        defer { activity = nil }
        do throws(AccountError) {
            try await services.importOfflineFile(at: url)
        } catch {
            actionFailure = error.offlineFileDescription.map {
                AccountActionFailure(title: String(localized: "Could not import the offline file"), message: $0)
            }
        }
    }

    // Nil when the key signed this Mac in; the message to show beside the key otherwise.
    func useLicenseKey(_ key: String) async -> String? {
        activity = .usingKey
        defer { activity = nil }
        do throws(AccountError) {
            _ = try await services.useLicenseKey(key)
        } catch {
            return error.licenseKeyDescription ?? String(localized: "Could not use this license key.")
        }
        presentsLicenseKey = false
        presentDeviceLimitIfReached()
        // The key may belong to another account than the one signed in before.
        forgetLoaded()
        await reload()
        return nil
    }

    func presentLicenseKey() {
        licenseKeyPrefill = services.storedLicenseKey
        presentsLicenseKey = true
    }

    func presentDeviceLimitIfReached() {
        if case .deviceLimitReached = services.access.state.refresh {
            presentsDeviceLimit = true
        }
    }

    private func forgetLoaded() {
        profile = AccountRemote()
        devices = AccountRemote()
    }
}
