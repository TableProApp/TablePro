//
//  AppActivationPolicySourceTests.swift
//  TableProTests
//
//  Coming forward for a person and being an app a person can see are the same decision, and the app
//  had 33 places making the first half of it on their own. A process serving MCP in the background
//  that activates without a Dock icon hands the person a window with no menu bar: no Cmd+W, no
//  Cmd+Q, no Edit menu.
//

import Foundation
import Testing

@Suite("App activation policy call sites")
struct AppActivationPolicySourceTests {
    private static let repositoryRoot: URL = {
        var url = URL(fileURLWithPath: #filePath)
        for _ in 0 ..< 5 {
            url.deleteLastPathComponent()
        }
        return url
    }()

    private static let owner = "AppActivationPolicyController.swift"

    private func swiftFiles(under directory: URL) -> [URL] {
        guard let walker = FileManager.default.enumerator(
            at: directory,
            includingPropertiesForKeys: nil
        ) else { return [] }
        return walker
            .compactMap { $0 as? URL }
            .filter { $0.pathExtension == "swift" && $0.lastPathComponent != Self.owner }
    }

    private func offenders(matching needle: String) throws -> [String] {
        let sources = swiftFiles(under: Self.repositoryRoot.appendingPathComponent("TablePro"))
        return try sources
            .filter { try String(contentsOf: $0, encoding: .utf8).contains(needle) }
            .map(\.lastPathComponent)
            .sorted()
    }

    @Test("Only the policy controller activates the app")
    func activationGoesThroughTheController() throws {
        let found = try offenders(matching: "NSApp.activate(")
        #expect(
            found.isEmpty,
            "Call AppActivationPolicyController.shared.activate() instead, so the app is one a person can see before it takes focus: \(found)"
        )
    }

    @Test("Only the policy controller sets the activation policy")
    func policyChangesGoThroughTheController() throws {
        let found = try offenders(matching: "setActivationPolicy(")
        #expect(
            found.isEmpty,
            "The activation policy has one owner, which is the only thing that can keep the Dock icon and the session's origin in step: \(found)"
        )
    }
}
