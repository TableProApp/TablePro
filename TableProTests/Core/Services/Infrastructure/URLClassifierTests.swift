//
//  URLClassifierTests.swift
//  TableProTests
//

import Foundation
@testable import TablePro
import TableProPluginKit
import Testing

@Suite("URLClassifier file extension routing", .serialized)
@MainActor
struct URLClassifierTests {
    private func withInspectorState<T>(
        lazy: [String: URL],
        active: [String: any DocumentInspectorPlugin] = [:],
        body: () throws -> T
    ) rethrows -> T {
        let originalLazy = PluginManager.shared.lazyInspectorFileExtensions
        let originalActive = PluginManager.shared.inspectorPlugins
        defer {
            PluginManager.shared.lazyInspectorFileExtensions = originalLazy
            PluginManager.shared.inspectorPlugins = originalActive
        }
        PluginManager.shared.lazyInspectorFileExtensions = lazy
        PluginManager.shared.inspectorPlugins = active
        return try body()
    }

    @Test("CSV routes to openInspectorFile when the extension is registered")
    func routesCSVWhenExtensionRegistered() {
        let csvURL = URL(fileURLWithPath: "/tmp/sample.csv")
        let stubPluginURL = URL(fileURLWithPath: "/tmp/stub.tableplugin")
        let intent = withInspectorState(lazy: ["csv": stubPluginURL]) {
            URLClassifier.classify(csvURL)
        }
        guard case .some(.success(.openInspectorFile(let routed))) = intent else {
            Issue.record("Expected .openInspectorFile, got \(String(describing: intent))")
            return
        }
        #expect(routed == csvURL)
    }

    @Test("CSV returns nil when no inspector plugin registers the extension")
    func returnsNilWhenExtensionMissing() {
        let csvURL = URL(fileURLWithPath: "/tmp/sample.csv")
        let intent = withInspectorState(lazy: [:]) {
            URLClassifier.classify(csvURL)
        }
        #expect(intent == nil)
    }
}
