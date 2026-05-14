//
//  WindowLayoutMigrationTests.swift
//  TableProTests
//

import Foundation
@testable import TablePro
import Testing

@Suite("WindowLayoutMigration")
@MainActor
struct WindowLayoutMigrationTests {
    private func makeDefaults() -> UserDefaults {
        let suiteName = "com.TablePro.tests.\(UUID().uuidString)"
        // swiftlint:disable:next force_unwrapping
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        return defaults
    }

    @Test("with no legacy keys, marks migration complete and writes nothing")
    func noLegacyKeysMarksComplete() {
        let defaults = makeDefaults()
        let connectionId = UUID()

        WindowLayoutMigration.migrate(defaults: defaults, connectionIds: [connectionId])

        #expect(defaults.bool(forKey: WindowLayoutMigration.migrationCompleteKey))
        #expect(defaults.object(forKey: WindowLayoutMigration.perConnectionSplitFramesKey(connectionId)) == nil)
        #expect(defaults.object(forKey: WindowLayoutMigration.perConnectionInspectorKey(connectionId)) == nil)
    }

    @Test("seeds the per-connection split frames from the legacy global key")
    func seedsSplitFrames() {
        let defaults = makeDefaults()
        let connectionId = UUID()
        let legacyFrames = ["frame-a", "frame-b"]
        defaults.set(legacyFrames, forKey: WindowLayoutMigration.splitFramesKey("com.TablePro.mainSplit"))

        WindowLayoutMigration.migrate(defaults: defaults, connectionIds: [connectionId])

        let seeded = defaults.array(forKey: WindowLayoutMigration.perConnectionSplitFramesKey(connectionId)) as? [String]
        #expect(seeded == legacyFrames)
        #expect(defaults.object(forKey: WindowLayoutMigration.splitFramesKey("com.TablePro.mainSplit")) == nil)
    }

    @Test("seeds the per-connection inspector flag from the legacy global key")
    func seedsInspectorFlag() {
        let defaults = makeDefaults()
        let connectionId = UUID()
        defaults.set(true, forKey: "com.TablePro.rightPanel.isPresented")

        WindowLayoutMigration.migrate(defaults: defaults, connectionIds: [connectionId])

        #expect(defaults.bool(forKey: WindowLayoutMigration.perConnectionInspectorKey(connectionId)))
        #expect(defaults.object(forKey: "com.TablePro.rightPanel.isPresented") == nil)
    }

    @Test("seeds every connection from the shared legacy value")
    func seedsEveryConnection() {
        let defaults = makeDefaults()
        let first = UUID()
        let second = UUID()
        defaults.set(false, forKey: "com.TablePro.rightPanel.isPresented")

        WindowLayoutMigration.migrate(defaults: defaults, connectionIds: [first, second])

        #expect(defaults.object(forKey: WindowLayoutMigration.perConnectionInspectorKey(first)) != nil)
        #expect(defaults.object(forKey: WindowLayoutMigration.perConnectionInspectorKey(second)) != nil)
        #expect(defaults.bool(forKey: WindowLayoutMigration.perConnectionInspectorKey(first)) == false)
    }

    @Test("does not overwrite an existing per-connection key")
    func doesNotOverwriteExisting() {
        let defaults = makeDefaults()
        let connectionId = UUID()
        defaults.set(true, forKey: "com.TablePro.rightPanel.isPresented")
        defaults.set(false, forKey: WindowLayoutMigration.perConnectionInspectorKey(connectionId))

        WindowLayoutMigration.migrate(defaults: defaults, connectionIds: [connectionId])

        #expect(defaults.bool(forKey: WindowLayoutMigration.perConnectionInspectorKey(connectionId)) == false)
    }

    @Test("is idempotent: a second run does not re-seed")
    func idempotentSecondRun() {
        let defaults = makeDefaults()
        let connectionId = UUID()
        defaults.set(true, forKey: "com.TablePro.rightPanel.isPresented")

        WindowLayoutMigration.migrate(defaults: defaults, connectionIds: [connectionId])
        // A stale legacy value reappearing must not be re-applied once complete.
        defaults.set(false, forKey: "com.TablePro.rightPanel.isPresented")
        WindowLayoutMigration.migrate(defaults: defaults, connectionIds: [connectionId])

        #expect(defaults.bool(forKey: WindowLayoutMigration.perConnectionInspectorKey(connectionId)))
        #expect(defaults.object(forKey: "com.TablePro.rightPanel.isPresented") != nil)
    }
}
