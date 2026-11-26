import Foundation
import Observation
import os
import TableProFFI
import TableProLogRedaction
import UIKit

// The TablePro account on this device: the core's account (core/docs/decisions/0047-the-apple-apps-sign-in-through-
// the-core.md) through the adapter the Mac uses. The app gates nothing on it: the server checks every call.
@MainActor @Observable
final class AccountModel: AccountBackendListener {
    typealias Opener = @MainActor (any AccountBackendListener, ManagedAppConfiguration)
        throws(AccountKeychainFailure) -> any AccountBackend

    enum Availability: Equatable {
        case opening
        case open
        // The Keychain is locked until the device is first unlocked; the next activation opens it.
        case waitingForUnlock
        case unavailable
    }

    private static let logger = Logger(subsystem: "com.TablePro", category: "AccountModel")

    private(set) var availability: Availability = .opening
    private(set) var snapshot = AccountSnapshot()
    private(set) var server: AccountServer = .production
    private(set) var license: AccountServerLicense?
    private(set) var isRestored = false
    private(set) var isBusy = false
    // A sign-out the person did not ask for, shown until the next sign-in.
    private(set) var involuntarySignOut: AccountSignOutCause?

    @ObservationIgnored private var backend: (any AccountBackend)?
    @ObservationIgnored private let opener: Opener
    @ObservationIgnored private var configuration: ManagedAppConfiguration
    // Every reading reaches the core in order, so one that stops the server is never overtaken by an older one.
    @ObservationIgnored private let readings: AsyncStream<ManagedPolicyArg>
    @ObservationIgnored private let reader: AsyncStream<ManagedPolicyArg>.Continuation

    init(configuration: ManagedAppConfiguration = .unmanaged, opener: @escaping Opener) {
        self.configuration = configuration
        self.opener = opener
        (readings, reader) = AsyncStream.makeStream(of: ManagedPolicyArg.self)
    }

    var isSignedIn: Bool {
        snapshot.state == .signedIn
    }

    var isPastDeviceLimit: Bool {
        if case .deviceLimitReached = snapshot.problem { return true }
        return false
    }

    func openIfNeeded() {
        guard backend == nil, availability != .unavailable else { return }
        do throws(AccountKeychainFailure) {
            let opened = try opener(self, configuration)
            backend = opened
            availability = .open
            publish()
            let readings = readings
            Task {
                for await policy in readings {
                    await opened.applyPolicy(policy)
                }
            }
            Task {
                await opened.waitUntilRestored()
                publish()
            }
        } catch .locked {
            availability = .waitingForUnlock
        } catch {
            Self.logger.error("The account did not open: \(LogRedaction.publicDescription(of: error), privacy: .public)")
            availability = .unavailable
        }
    }

    // The organization's values read again. When they no longer allow the server signed in to, the core calls it no
    // more until the next launch (core ADR 0055); an account not open yet opens with them.
    func apply(_ configuration: ManagedAppConfiguration) {
        guard configuration != self.configuration else { return }
        self.configuration = configuration
        reader.yield(configuration.coreArgument)
    }

    // Back in the foreground: a device another one removed may have freed a slot.
    func sceneBecameActive() {
        openIfNeeded()
        guard let backend, isPastDeviceLimit else { return }
        Task {
            do throws(AccountError) {
                _ = try await backend.refreshPastDeviceLimit()
            } catch {
                Self.logger.warning("Refresh past the device limit failed: \(error.logShape, privacy: .public)")
            }
            publish()
        }
    }

    func signIn(using authenticator: some WebAuthenticating) async throws(AccountError) {
        let backend = try await restoredBackend()
        guard backend.status().state != .signedIn else { throw .signOutFirst }
        isBusy = true
        defer { isBusy = false }
        involuntarySignOut = nil
        try await backend.signIn(using: authenticator)
        publish()
    }

    // Signs out here even when the server could not be told.
    func signOut() async {
        guard let backend else { return }
        isBusy = true
        defer { isBusy = false }
        do throws(AccountError) {
            try await backend.signOut()
        } catch {
            Self.logger.warning("The server was not told of the sign-out: \(error.logShape, privacy: .public)")
        }
        publish()
    }

    // Nil drops the choice, for the organization's server or else tablepro.app.
    func chooseServer(_ url: URL?) async throws(AccountError) {
        let backend = try await restoredBackend()
        guard backend.status().state != .signedIn else { throw .signOutFirst }
        isBusy = true
        defer { isBusy = false }
        try await backend.chooseServer(url)
        publish()
    }

    func refresh() async throws(AccountError) {
        let backend = try await restoredBackend()
        defer { publish() }
        try await backend.refresh()
    }

    func devices() async throws(AccountError) -> [AccountDevice] {
        try await restoredBackend().devices()
    }

    func removeDevice(_ id: String) async throws(AccountError) {
        let backend = try await restoredBackend()
        try await backend.removeDevice(id)
        do throws(AccountError) {
            try await backend.refresh()
        } catch {
            Self.logger.warning("Refresh after removing a device failed: \(error.logShape, privacy: .public)")
        }
        publish()
    }

    // MARK: - AccountBackendListener

    func accountStatusChanged(signedOutBy cause: AccountSignOutCause?) {
        publish()
        guard let cause, cause != .user, !isSignedIn else { return }
        Self.logger.notice("Signed out on this device: \(String(describing: cause), privacy: .public)")
        involuntarySignOut = cause
    }

    // MARK: - Private

    private func restoredBackend() async throws(AccountError) -> any AccountBackend {
        guard let backend else { throw .network("the account is not open") }
        await backend.waitUntilRestored()
        return backend
    }

    private func publish() {
        guard let backend else { return }
        // Read before the snapshot: once the restore is marked, the snapshot read after it holds what it restored.
        isRestored = backend.isRestored
        snapshot = backend.status()
        server = backend.server()
        license = backend.license()
    }
}

extension AccountModel {
    // The account at its place in Application Support, under the organization's managed server values.
    static func live(configuration: ManagedAppConfiguration, supportDirectory: URL = LibraryStorage.defaultDirectory)
        -> AccountModel {
        let device = MobileAccountSetup.Device.current()
        let developmentStack = isDebugBuild ? AccountDevelopmentStack.read(ProcessInfo.processInfo.environment) : nil
        return AccountModel(configuration: configuration) { listener, managed throws(AccountKeychainFailure) in
            let items = AccountKeychainItems()
            let config = MobileAccountSetup.config(
                deviceID: try AccountDeviceID.current(items: items),
                device: device,
                accountFolder: MobileAccountSetup.accountFolder(in: supportDirectory),
                managed: managed,
                developmentStack: developmentStack
            )
            let backend = CoreAccountBackend(
                config: config,
                appVersion: device.appVersion,
                keychain: MobileAccountKeychain(items: items)
            )
            backend.setListener(listener)
            return backend
        }
    }

    private static var isDebugBuild: Bool {
        #if DEBUG
        true
        #else
        false
        #endif
    }
}

// What the iOS app hands the core's account when it opens it.
nonisolated enum MobileAccountSetup {
    struct Device: Equatable, Sendable {
        let name: String
        let appVersion: String
        // With the system's name, "iOS 26.1" or "iPadOS 26.1", as the server lists it.
        let osVersion: String

        @MainActor
        static func current() -> Device {
            let device = UIDevice.current
            return Device(
                name: device.name,
                appVersion: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "",
                osVersion: "\(device.systemName) \(device.systemVersion)"
            )
        }
    }

    // Kept out of backups: a restore onto another device brings none of the Keychain items the file goes with.
    static func accountFolder(in supportDirectory: URL) -> URL {
        var folder = supportDirectory.appendingPathComponent("Account", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            var values = URLResourceValues()
            values.isExcludedFromBackup = true
            try folder.setResourceValues(values)
        } catch {
            Logger(subsystem: "com.TablePro", category: "AccountModel")
                .warning("The account folder is not kept out of backups: \(LogRedaction.publicDescription(of: error), privacy: .public)")
        }
        return folder
    }

    static func config(
        deviceID: String,
        device: Device,
        accountFolder: URL,
        managed: ManagedAppConfiguration,
        developmentStack: AccountDevelopmentStack?
    ) -> AccountConfig {
        AccountConfig(
            accountUrl: developmentStack?.accountURL,
            apiUrl: developmentStack?.apiBase,
            entitlementKeys: developmentStack?.entitlementKeys ?? [],
            deviceName: device.name,
            appVersion: device.appVersion,
            osVersion: device.osVersion,
            accountFile: accountFolder.appendingPathComponent("account.json").path,
            callbackFinished: "",
            callbackUnknown: "",
            machineGuid: nil,
            client: .ios,
            machineId: deviceID,
            policy: managed.coreArgument,
            legacyEntitlementFile: nil,
            licenseKeys: developmentStack?.licenseKeys ?? []
        )
    }
}

nonisolated extension AccountError {
    var logShape: String {
        LogRedaction.publicDescription(of: self)
    }
}
