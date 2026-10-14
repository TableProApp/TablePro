//
//  AppStorageEnvironment.swift
//  TablePro
//

import Foundation
import os
import TableProPluginKit

/// Every store, the defaults suite and the keychain resolve inside `TABLEPRO_UI_TEST_SANDBOX` when it is set.
/// The app cannot detect XCUITest (no XCTest variable reaches it), so `TABLEPRO_UI_TESTING` without a sandbox is fatal.
internal final class AppStorageEnvironment: @unchecked Sendable {
    internal static let shared = AppStorageEnvironment.resolve()

    /// Every store appends its own `TablePro/...` subpath, so moving the root moves all of them.
    internal let applicationSupportRoot: URL
    internal let defaults: UserDefaults
    internal let keychain: any KeychainStoring
    internal let isIsolated: Bool
    internal let isUnitTestHost: Bool
    internal let defaultsSuiteName: String?

    internal var supportDirectory: URL {
        applicationSupportRoot.appendingPathComponent("TablePro", isDirectory: true)
    }

    private static let logger = Logger(subsystem: "com.TablePro", category: "AppStorageEnvironment")

    internal static let uiTestingVariable = "TABLEPRO_UI_TESTING"
    internal static let sandboxVariable = PluginHostStorage.sandboxVariable
    internal static let unitTestHostVariable = "XCTestConfigurationFilePath"
    internal static let sandboxMarkerName = ".defaults-suite"

    private init(
        applicationSupportRoot: URL,
        defaults: UserDefaults,
        keychain: any KeychainStoring,
        isIsolated: Bool,
        isUnitTestHost: Bool,
        defaultsSuiteName: String? = nil
    ) {
        self.applicationSupportRoot = applicationSupportRoot
        self.defaults = defaults
        self.keychain = keychain
        self.isIsolated = isIsolated
        self.isUnitTestHost = isUnitTestHost
        self.defaultsSuiteName = defaultsSuiteName
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
    }

    internal static func decision(for environment: [String: String]) -> Decision {
        let sandboxPath = environment[sandboxVariable]?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let sandboxPath, !sandboxPath.isEmpty {
            return .isolated(path: sandboxPath)
        }
        return environment[uiTestingVariable] == "1" ? .refuseToLaunch : .production
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
        return AppStorageEnvironment(
            applicationSupportRoot: root,
            defaults: defaults,
            keychain: SandboxKeychainStore(fileURL: supportDirectory.appendingPathComponent("keychain.json")),
            isIsolated: true,
            isUnitTestHost: isUnitTestHost,
            defaultsSuiteName: suiteName
        )
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
