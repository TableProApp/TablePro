//
//  AppStorageEnvironment.swift
//  TablePro
//

import Foundation
import os
import TableProPluginKit

/// The three roots every persistent store resolves through: the Application Support directory, the
/// defaults domain, and the keychain. Production resolves them to the user's own locations. A UI
/// test names a throwaway directory in `TABLEPRO_UI_TEST_SANDBOX` and gets all three inside it, so
/// driving the app from a test can never read or write the data of the person running it.
///
/// The app cannot detect on its own that it is running under XCUITest. Measured on macOS 27, the
/// app under test receives no `XCTestConfigurationFilePath`, no `XCTestSessionIdentifier` and no
/// XCTest `DYLD_INSERT_LIBRARIES`; the only test-related variable present is the one the test
/// itself sets. Every other marker (`XCODE_SCHEME_NAME`, `NSUnbufferedIO`) is also present on an
/// ordinary Run from Xcode, so none of them can gate this. The guard is therefore two layers: at
/// runtime `TABLEPRO_UI_TESTING` without a sandbox beside it is fatal, which covers every test that
/// opts in; and at build time `UITestCase` is the only way a UI test may construct an application,
/// which covers a new test that opts into neither.
internal final class AppStorageEnvironment: @unchecked Sendable {
    internal static let shared = AppStorageEnvironment.resolve()

    /// The Application Support root. Every store already appends its own `TablePro/...` subpath to
    /// this, so redirecting the root alone moves all of them and leaves each site's own layout
    /// untouched.
    internal let applicationSupportRoot: URL
    internal let defaults: UserDefaults
    internal let keychain: any KeychainStoring
    internal let isIsolated: Bool

    /// Named so a test can remove the domain once the app it belongs to is gone. The app cannot do
    /// it itself: `XCUIApplication.terminate()` kills the process, so `applicationWillTerminate`
    /// never runs under a UI test.
    internal let defaultsSuiteName: String?

    internal var supportDirectory: URL {
        applicationSupportRoot.appendingPathComponent("TablePro", isDirectory: true)
    }

    private static let logger = Logger(subsystem: "com.TablePro", category: "AppStorageEnvironment")

    internal static let uiTestingVariable = "TABLEPRO_UI_TESTING"
    internal static let sandboxVariable = PluginHostStorage.sandboxVariable

    private init(
        applicationSupportRoot: URL,
        defaults: UserDefaults,
        keychain: any KeychainStoring,
        isIsolated: Bool,
        defaultsSuiteName: String? = nil
    ) {
        self.applicationSupportRoot = applicationSupportRoot
        self.defaults = defaults
        self.keychain = keychain
        self.isIsolated = isIsolated
        self.defaultsSuiteName = defaultsSuiteName
    }


    /// Resolved from `main.swift` before anything else runs. A storage singleton reached from a
    /// static initializer would otherwise have computed a production path already, and the sandbox
    /// would apply to whatever happened to be touched after it.
    internal static func bootstrap() {
        _ = shared
    }

    /// The choice the environment variables imply, separated from acting on it so it can be tested
    /// without a process that has already resolved its storage.
    internal enum Decision: Equatable {
        case production
        case isolated(path: String)
        /// A UI test opted in but named no sandbox. Launching would drive the real store.
        case refuseToLaunch
    }

    internal static func decision(for environment: [String: String]) -> Decision {
        let sandboxPath = environment[sandboxVariable]?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let sandboxPath, !sandboxPath.isEmpty {
            return .isolated(path: sandboxPath)
        }
        return environment[uiTestingVariable] == "1" ? .refuseToLaunch : .production
    }

    private static func resolve() -> AppStorageEnvironment {
        switch decision(for: ProcessInfo.processInfo.environment) {
        case .production:
            return production()
        case let .isolated(path):
            return isolated(at: URL(fileURLWithPath: path))
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

    private static func production() -> AppStorageEnvironment {
        AppStorageEnvironment(
            applicationSupportRoot: productionRoot(),
            defaults: .standard,
            keychain: KeychainHelper.shared,
            isIsolated: false
        )
    }

    /// A failure to prepare the sandbox is fatal rather than a fallback to production. Falling back
    /// is what turns a broken test setup into a polluted store, which is the whole failure this
    /// type exists to prevent.
    private static func isolated(at root: URL) -> AppStorageEnvironment {
        let supportDirectory = root.appendingPathComponent("TablePro", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: supportDirectory, withIntermediateDirectories: true)
        } catch {
            logger.fault(
                """
                Refusing to launch: could not create the storage sandbox at \
                \(supportDirectory.path, privacy: .public): \(error.localizedDescription, privacy: .public)
                """
            )
            exit(EXIT_FAILURE)
        }

        let suiteName = PluginHostStorage.suiteName(forSandboxAt: root.path)
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            logger.fault("Refusing to launch: could not open the defaults suite \(suiteName, privacy: .public)")
            exit(EXIT_FAILURE)
        }

        logger.notice("Storage sandboxed at \(supportDirectory.path, privacy: .public)")
        return AppStorageEnvironment(
            applicationSupportRoot: root,
            defaults: defaults,
            keychain: SandboxKeychainStore(fileURL: supportDirectory.appendingPathComponent("keychain.json")),
            isIsolated: true,
            defaultsSuiteName: suiteName
        )
    }

    /// The one place in the app allowed to ask the file system for this. Every other store goes
    /// through `applicationSupportRoot`, and a SwiftLint rule keeps it that way.
    private static func productionRoot() -> URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
    }
}
