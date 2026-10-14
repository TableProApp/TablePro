import Foundation
@testable import TablePro
import TableProPluginKit
import Testing

struct AppStorageEnvironmentTests {
    private let sandbox = AppStorageEnvironment.sandboxVariable
    private let uiTesting = AppStorageEnvironment.uiTestingVariable

    @Test("An ordinary launch uses the real store")
    func productionWhenNothingIsSet() {
        #expect(AppStorageEnvironment.decision(for: [:]) == .production)
        #expect(AppStorageEnvironment.decision(for: ["PATH": "/usr/bin"]) == .production)
    }

    @Test("A named sandbox is honoured")
    func isolatedWhenSandboxIsNamed() {
        let decision = AppStorageEnvironment.decision(for: [sandbox: "/tmp/somewhere"])
        #expect(decision == .isolated(path: "/tmp/somewhere"))
    }

    /// The failure this type exists to prevent: a UI test that names no sandbox would drive the real store.
    @Test("A UI test with no sandbox refuses to launch rather than falling back")
    func refusesWhenUiTestingHasNoSandbox() {
        #expect(AppStorageEnvironment.decision(for: [uiTesting: "1"]) == .refuseToLaunch)
        #expect(AppStorageEnvironment.decision(for: [uiTesting: "1", sandbox: ""]) == .refuseToLaunch)
        #expect(AppStorageEnvironment.decision(for: [uiTesting: "1", sandbox: "   "]) == .refuseToLaunch)
    }

    @Test("A sandbox wins even without the opt-in flag, so nothing silently escapes it")
    func sandboxAloneIsEnough() {
        #expect(AppStorageEnvironment.decision(for: [sandbox: "/tmp/x"]) == .isolated(path: "/tmp/x"))
    }

    @Test("The unit test host is told apart by the configuration XCTest hands it, and a UI test is not")
    func unitTestHostIsDetected() {
        let unitTestHost = AppStorageEnvironment.unitTestHostVariable
        #expect(!AppStorageEnvironment.isUnitTestHost([:]))
        #expect(!AppStorageEnvironment.isUnitTestHost([uiTesting: "1", sandbox: "/tmp/x"]))
        #expect(AppStorageEnvironment.isUnitTestHost([unitTestHost: "/tmp/run.xctestconfiguration"]))
        #expect(AppStorageEnvironment.shared.isUnitTestHost)
    }

    @Test("Whitespace around the path is not a path")
    func trimsThePath() {
        #expect(AppStorageEnvironment.decision(for: [sandbox: "  /tmp/y  "]) == .isolated(path: "/tmp/y"))
    }

    // Fails when TestPlans/Unit.xctestplan stops handing the host its sandbox variable.
    @Test("The unit test host runs inside the sandbox the Unit plan names")
    func unitTestHostIsSandboxed() {
        let environment = AppStorageEnvironment.shared
        #expect(environment.isIsolated)
        #expect(environment.applicationSupportRoot.lastPathComponent == "UnitTestStorage")
        #expect(
            environment.defaultsSuiteName
                == PluginHostStorage.suiteName(forSandboxAt: environment.applicationSupportRoot.path)
        )
    }

    // The literal pins a digest that every process computes alike; `Hasher` would pass the other checks.
    @Test("Each sandbox path gets its own suite under the uitest prefix")
    func suiteNameFollowsTheSandboxPath() {
        let suite = PluginHostStorage.suiteName(forSandboxAt: "/tmp/TableProSandbox")
        #expect(suite == "com.TablePro.uitest.0b4547851efcce3e")
        #expect(PluginHostStorage.suiteName(forSandboxAt: "/tmp/TableProSandbox/") == suite)
        #expect(PluginHostStorage.suiteName(forSandboxAt: "/tmp/OtherSandbox") != suite)
    }

    @Test("A new sandbox directory starts with an empty suite, and a relaunch into it keeps the suite")
    func newSandboxEmptiesTheSuite() throws {
        let suiteName = "com.TablePro.tests.AppStorageEnvironmentTests"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("AppStorageEnvironmentTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer {
            defaults.removePersistentDomain(forName: suiteName)
            try? FileManager.default.removeItem(at: directory)
        }

        defaults.set("left by an earlier sandbox", forKey: "probe")
        AppStorageEnvironment.emptyDefaultsIfNewSandbox(defaults, suiteName: suiteName, supportDirectory: directory)
        #expect(defaults.string(forKey: "probe") == nil)

        defaults.set("written by this sandbox", forKey: "probe")
        AppStorageEnvironment.emptyDefaultsIfNewSandbox(defaults, suiteName: suiteName, supportDirectory: directory)
        #expect(defaults.string(forKey: "probe") == "written by this sandbox")
    }
}
