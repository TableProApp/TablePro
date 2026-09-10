import Foundation
import Testing
@testable import TablePro

@Suite("AppStorageEnvironment")
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

    /// The failure this whole type exists to prevent: a UI test that opts in but names no sandbox
    /// would otherwise drive the developer's real connections, keychain and preferences.
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

    @Test("Whitespace around the path is not a path")
    func trimsThePath() {
        #expect(AppStorageEnvironment.decision(for: [sandbox: "  /tmp/y  "]) == .isolated(path: "/tmp/y"))
    }

    /// The runtime guard only fires for a test that sets the opt-in flag. A test that sets neither
    /// variable is caught here instead: `UITestCase` is the only supported way to launch the app,
    /// and it always names a sandbox.
    @Test("Every UI test launches through UITestCase")
    func everyUiTestGoesThroughTheBaseClass() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let suiteDirectory = root.appendingPathComponent("TableProUITests")
        /// Walked rather than listed. XcodeGen globs the target recursively, so a suite added under
        /// TableProUITests/Editor/ would compile and run while a top-level listing never saw it.
        let enumerator = FileManager.default.enumerator(atPath: suiteDirectory.path)
        let baseClass = "Support/UITestCase.swift"
        let paths = (enumerator?.allObjects as? [String] ?? [])
            .filter { $0.hasSuffix(".swift") && $0 != baseClass }
        #expect(!paths.isEmpty, "The UI test directory should not be empty at \(suiteDirectory.path)")

        for path in paths {
            let source = try String(contentsOf: suiteDirectory.appendingPathComponent(path), encoding: .utf8)
            #expect(
                !source.contains("XCUIApplication()"),
                "\(path) constructs an application directly; use UITestCase.launchApp() so it gets a sandbox"
            )
            #expect(
                !source.contains(": XCTestCase"),
                "\(path) subclasses XCTestCase; UI tests must subclass UITestCase"
            )
        }
    }
}
