//
//  AppStorageEnvironment.swift
//  TablePro
//

import Foundation
import os
import TableProPluginKit

/// Every store, the defaults suite and the keychain resolve inside `TABLEPRO_UI_TEST_SANDBOX` when it is set.
/// The app cannot detect XCUITest (no XCTest variable reaches it), so `TABLEPRO_UI_TESTING` without a sandbox is fatal.
/// A Debug build also takes `TABLEPRO_DEVICE_PROFILE`: a device of its own beside the real one, with its own folder,
/// defaults suite, Keychain service and machine ID, whose account, sync and Team Library run as in the real store.
internal final class AppStorageEnvironment: @unchecked Sendable {
    internal static let shared = AppStorageEnvironment.resolve()

    /// Every store appends its own `TablePro/...` subpath, so moving the root moves all of them.
    internal let applicationSupportRoot: URL
    internal let defaults: UserDefaults
    internal let keychain: any KeychainStoring
    internal let deviceOnlyKeychain: any KeychainStoring
    // The sync engine's keys and anchor, which need Keychain classes `KeychainStoring` does not carry.
    internal let deviceItems: any DeviceKeychainItems
    internal let isIsolated: Bool
    internal let isUnitTestHost: Bool
    internal let defaultsSuiteName: String?
    internal let deviceProfile: String?

    // What lives outside the app's own folder and suite (AppKit's records in the standard domain, the OpenSSH item,
    // other apps' MCP settings, Keychain items with fixed names) is the real store's alone.
    internal var isProductionStore: Bool {
        !isIsolated && deviceProfile == nil
    }

    internal var supportDirectory: URL {
        applicationSupportRoot.appendingPathComponent("TablePro", isDirectory: true)
    }

    // Nil means the user's Trash. A sandboxed run keeps what it trashes inside the sandbox, so a
    // test never leaves files in the Trash of the Mac running it.
    internal var trashDirectory: URL? {
        isIsolated ? supportDirectory.appendingPathComponent("Trash", isDirectory: true) : nil
    }

    private static let logger = Logger(subsystem: "com.TablePro", category: "AppStorageEnvironment")

    internal static let uiTestingVariable = "TABLEPRO_UI_TESTING"
    internal static let sandboxVariable = PluginHostStorage.sandboxVariable
    internal static let unitTestHostVariable = "XCTestConfigurationFilePath"
    internal static let deviceProfileVariable = "TABLEPRO_DEVICE_PROFILE"
    internal static let sandboxMarkerName = ".defaults-suite"

    private init(
        applicationSupportRoot: URL,
        defaults: UserDefaults,
        keychain: any KeychainStoring,
        deviceOnlyKeychain: any KeychainStoring,
        deviceItems: any DeviceKeychainItems,
        isIsolated: Bool,
        isUnitTestHost: Bool,
        defaultsSuiteName: String? = nil,
        deviceProfile: String? = nil
    ) {
        self.applicationSupportRoot = applicationSupportRoot
        self.defaults = defaults
        self.keychain = keychain
        self.deviceOnlyKeychain = deviceOnlyKeychain
        self.deviceItems = deviceItems
        self.isIsolated = isIsolated
        self.isUnitTestHost = isUnitTestHost
        self.defaultsSuiteName = defaultsSuiteName
        self.deviceProfile = deviceProfile
    }

    /// Called first from `main.swift`, before a static initializer can resolve a production path.
    internal static func bootstrap() {
        _ = shared
    }

    internal enum Decision: Equatable {
        case production
        case isolated(path: String)
        /// A UI test opted in but named no sandbox; launching would drive the real store.
        case refuseToLaunch
        case deviceProfile(name: String)
        /// A profile name that cannot name a folder, suite and Keychain service; launching would drive the real store.
        case refuseProfile
    }

    internal static func decision(
        for environment: [String: String],
        isDebugBuild: Bool = AppStorageEnvironment.isDebugBuild
    ) -> Decision {
        let sandboxPath = environment[sandboxVariable]?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let sandboxPath, !sandboxPath.isEmpty {
            return .isolated(path: sandboxPath)
        }
        if environment[uiTestingVariable] == "1" {
            return .refuseToLaunch
        }
        guard isDebugBuild,
              let profile = environment[deviceProfileVariable]?.trimmingCharacters(in: .whitespacesAndNewlines),
              !profile.isEmpty
        else { return .production }
        return isDeviceProfileName(profile) ? .deviceProfile(name: profile) : .refuseProfile
    }

    internal static func isDeviceProfileName(_ name: String) -> Bool {
        name.count <= 32 && name.range(of: "^[A-Za-z0-9_-]+$", options: .regularExpression) != nil
    }

    internal static var isDebugBuild: Bool {
        #if DEBUG
        true
        #else
        false
        #endif
    }

    internal static func isUnitTestHost(_ environment: [String: String]) -> Bool {
        environment[unitTestHostVariable] != nil
    }

    private static func resolve() -> AppStorageEnvironment {
        let environment = ProcessInfo.processInfo.environment
        let isUnitTestHost = isUnitTestHost(environment)
        switch decision(for: environment) {
        case .production:
            return production(isUnitTestHost: isUnitTestHost)
        case let .isolated(path):
            return isolated(at: URL(fileURLWithPath: path), isUnitTestHost: isUnitTestHost)
        case let .deviceProfile(name):
            return deviceProfile(named: name, isUnitTestHost: isUnitTestHost)
        case .refuseProfile:
            logger.fault(
                """
                Refusing to launch: \(deviceProfileVariable, privacy: .public) must be 1 to 32 letters, digits, \
                hyphens or underscores.
                """
            )
            exit(EXIT_FAILURE)
        case .refuseToLaunch:
            logger.fault(
                """
                Refusing to launch: \(uiTestingVariable, privacy: .public) is set but \
                \(sandboxVariable, privacy: .public) is not. A UI test must run against its own \
                storage, never the real one.
                """
            )
            exit(EXIT_FAILURE)
        }
    }

    private static func production(isUnitTestHost: Bool) -> AppStorageEnvironment {
        AppStorageEnvironment(
            applicationSupportRoot: productionRoot(),
            defaults: .standard,
            keychain: KeychainHelper.shared,
            deviceOnlyKeychain: KeychainHelper(followsPasswordSync: false),
            deviceItems: SystemDeviceKeychainItems(),
            isIsolated: false,
            isUnitTestHost: isUnitTestHost
        )
    }

    /// Fatal rather than a fallback, which would turn a broken test setup into a polluted real store.
    private static func isolated(at root: URL, isUnitTestHost: Bool) -> AppStorageEnvironment {
        let supportDirectory = root.appendingPathComponent("TablePro", isDirectory: true)
        do {
            // The Unit plan reuses one sandbox path per checkout, so every host launch starts empty.
            if isUnitTestHost, FileManager.default.fileExists(atPath: supportDirectory.path) {
                try FileManager.default.removeItem(at: supportDirectory)
            }
            try FileManager.default.createDirectory(at: supportDirectory, withIntermediateDirectories: true)
        } catch {
            logger.fault(
                """
                Refusing to launch: could not create the storage sandbox at \
                \(supportDirectory.path, privacy: .private(mask: .hash)): \(error.publicLogShape, privacy: .public)
                """
            )
            exit(EXIT_FAILURE)
        }

        let suiteName = PluginHostStorage.suiteName(forSandboxAt: root.path)
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            logger.fault("Refusing to launch: could not open the defaults suite \(suiteName, privacy: .public)")
            exit(EXIT_FAILURE)
        }
        emptyDefaultsIfNewSandbox(defaults, suiteName: suiteName, supportDirectory: supportDirectory)

        logger.notice("Storage sandboxed at \(supportDirectory.path, privacy: .private(mask: .hash))")
        let keychain = SandboxKeychainStore(fileURL: supportDirectory.appendingPathComponent("keychain.json"))
        return AppStorageEnvironment(
            applicationSupportRoot: root,
            defaults: defaults,
            keychain: keychain,
            deviceOnlyKeychain: keychain,
            deviceItems: SandboxDeviceKeychainItems(fileURL: supportDirectory.appendingPathComponent("device-keychain.json")),
            isIsolated: true,
            isUnitTestHost: isUnitTestHost,
            defaultsSuiteName: suiteName
        )
    }

    // Its folder sits beside the real one; its Keychain items take a service of their own in the same access group,
    // and iCloud Keychain stays off, as CloudKit does (SyncEngineHost).
    private static func deviceProfile(named name: String, isUnitTestHost: Bool) -> AppStorageEnvironment {
        let root = productionRoot().appendingPathComponent("TablePro-\(name)", isDirectory: true)
        let supportDirectory = root.appendingPathComponent("TablePro", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: supportDirectory, withIntermediateDirectories: true)
        } catch {
            logger.fault(
                """
                Refusing to launch: could not create the device profile's folder at \
                \(supportDirectory.path, privacy: .private(mask: .hash)): \(error.publicLogShape, privacy: .public)
                """
            )
            exit(EXIT_FAILURE)
        }

        let suiteName = deviceProfileSuiteName(name)
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            logger.fault("Refusing to launch: could not open the defaults suite \(suiteName, privacy: .public)")
            exit(EXIT_FAILURE)
        }
        emptyDefaultsIfNewSandbox(defaults, suiteName: suiteName, supportDirectory: supportDirectory)

        logger.notice("Device profile \(name, privacy: .public) at \(supportDirectory.path, privacy: .private(mask: .hash))")
        let service = deviceProfileSuiteName(name)
        return AppStorageEnvironment(
            applicationSupportRoot: root,
            defaults: defaults,
            keychain: KeychainHelper(service: service, passwordSyncSetting: { false }),
            deviceOnlyKeychain: KeychainHelper(service: service, followsPasswordSync: false),
            deviceItems: ProfileDeviceKeychainItems(base: SystemDeviceKeychainItems(), profile: name),
            isIsolated: false,
            isUnitTestHost: isUnitTestHost,
            defaultsSuiteName: suiteName,
            deviceProfile: name
        )
    }

    internal static func deviceProfileSuiteName(_ name: String) -> String {
        "com.TablePro.profile.\(name)"
    }

    /// cfprefsd keeps a suite after its sandbox directory is deleted, so a directory without the
    /// marker is a new sandbox and gets an empty suite; a relaunch into the same directory keeps it.
    internal static func emptyDefaultsIfNewSandbox(_ defaults: UserDefaults, suiteName: String, supportDirectory: URL) {
        let marker = supportDirectory.appendingPathComponent(sandboxMarkerName, isDirectory: false)
        guard !FileManager.default.fileExists(atPath: marker.path) else { return }
        defaults.removePersistentDomain(forName: suiteName)
        if !FileManager.default.createFile(atPath: marker.path, contents: Data()) {
            logger.error("Could not mark the sandbox, so the next launch empties its defaults again")
        }
    }

    /// The only direct lookup; a SwiftLint rule sends every other store through `applicationSupportRoot`.
    private static func productionRoot() -> URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
    }
}
