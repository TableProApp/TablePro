//
//  SetupGuideModelTests.swift
//  TableProTests
//

import Foundation
@testable import TablePro
import TableProImport
import TableProTestSupport
import Testing

@MainActor
struct SetupGuideModelTests {
    private struct StubImporter: ForeignAppImporter {
        let id: String
        var readsPasswordsFromKeychain = false
        var displayName: String { id }
        var symbolName: String { "cylinder" }
        var appBundleIdentifier: String { "test.\(id)" }
        var savedQuerySupport: ForeignSavedQuerySupport { .unavailable(reason: "none") }

        func installedAppURL() -> URL? { nil }
        func hasDataAtDefaultLocation() -> Bool { true }
        func inventory() throws -> ForeignAppInventory { .empty }

        func collect(_ request: ForeignImportRequest) throws -> CollectedImport {
            throw CocoaError(.featureUnsupported)
        }
    }

    private struct ReadFailure: LocalizedError {
        var errorDescription: String? { "The file is damaged." }
    }

    @MainActor
    private final class Recorder {
        var reads: [String] = []
        var requests: [ForeignImportRequest] = []
        var announcements: [String] = []
        var endings: [SetupGuideEnding] = []
        var failing: Set<String> = []
    }

    private static func row(
        _ id: String,
        connections: Int,
        availability: ForeignSourceAvailability = .available,
        keychain: Bool = false
    ) -> ForeignSourceRow {
        ForeignSourceRow(
            importer: StubImporter(id: id, readsPasswordsFromKeychain: keychain),
            availability: availability,
            inventory: ForeignAppInventory(connections: connections, savedQueries: 0, keychainPrompts: keychain ? connections : 0)
        )
    }

    private static func read(_ id: String) throws -> ForeignAppRead {
        let collected = CollectedImport(
            bundle: try ConnectionBundleBuilder(appVersion: "Tests").build(),
            source: .file(name: "\(id).tablepro")
        )
        let preview = ConnectionImportAnalyzer.analyze(
            collected,
            library: ImportLibrarySnapshot(),
            environment: ImportEnvironment(
                rules: ImportRules(maximumGroupDepth: 3, supportsSavedQueries: true, supportsCredentialProfiles: true),
                registeredTypeIds: [],
                fileExists: { _ in true }
            )
        )
        return ForeignAppRead(preview: preview, title: "Import from \(id)", banner: nil)
    }

    private static func model(
        _ recorder: Recorder,
        probe: @escaping @Sendable () async -> Set<String> = { [] },
        rows: [ForeignSourceRow] = [],
        importers: [any ForeignAppImporter]? = nil,
        count: @escaping @Sendable (any ForeignAppImporter) async -> ForeignSourceRow = {
            await ForeignSourceScanner.countedRow(for: $0)
        },
        keyboard: KeyboardSettings = .default,
        catalog: KeyboardPresetCatalog? = nil,
        clock: any Clock<Duration> = ContinuousClock()
    ) -> SetupGuideModel {
        let model = SetupGuideModel(dependencies: SetupGuideModel.Dependencies(
            probe: probe,
            scan: { reach in
                guard let importers else { return rows }
                return await ForeignSourceScanner.scan(importers, reach: reach)
            },
            count: count,
            read: { importer, request in
                recorder.reads.append(importer.id)
                recorder.requests.append(request)
                if recorder.failing.contains(importer.id) {
                    throw ReadFailure()
                }
                return try Self.read(importer.id)
            },
            announce: { recorder.announcements.append($0) },
            keyboard: { keyboard },
            presetCatalog: catalog,
            clock: clock,
            probeLimit: .seconds(2)
        ))
        model.onEnd = { recorder.endings.append($0) }
        return model
    }

    private static func isReviewing(_ model: SetupGuideModel) -> Bool {
        if case .review = model.importPhase { return true }
        return false
    }

    private static func reviewId(_ model: SetupGuideModel) -> UUID? {
        if case .review(_, let id) = model.importPhase { return id }
        return nil
    }

    private static func isChoosing(_ model: SetupGuideModel) -> Bool {
        if case .choosing = model.importPhase { return true }
        return false
    }

    // MARK: - First step

    @Test("An app found by the probe opens the guide on import, with no Back to a step never shown")
    func probeOpensOnImport() async throws {
        let recorder = Recorder()
        let model = Self.model(recorder, probe: { ["alpha"] }, rows: [Self.row("alpha", connections: 3)])

        await model.start().value

        #expect(model.step == .import)
        #expect(!model.canGoBack)
        try await waitUntil { model.hasScanned }
        #expect(model.ticked == ["alpha"])
    }

    @Test("With nothing found the guide stays on origin")
    func probeFindsNothing() async {
        let recorder = Recorder()
        let model = Self.model(recorder)

        await model.start().value

        #expect(model.step == .origin)
        #expect(!model.canGoBack)
        #expect(!model.isWaitingForProbe)
    }

    @Test("A probe answering after its limit leaves the guide on origin")
    func lateProbeIsIgnored() async throws {
        let recorder = Recorder()
        let gate = AsyncGate()
        let clock = ManualClock()
        let model = Self.model(recorder, probe: {
            await gate.wait()
            return ["alpha"]
        }, clock: clock)

        let probe = model.start()
        await clock.waitUntilSleeping()
        clock.advance(by: .seconds(2))
        try await waitUntil { !model.isWaitingForProbe }
        await gate.open()
        await probe.value

        #expect(model.step == .origin)
        #expect(!model.hasScanned, "No scan starts for an answer nobody waited for")
    }

    @Test("A choice made while the probe runs stays, and the probe's answer moves nothing")
    func choiceDuringProbeWins() async {
        let recorder = Recorder()
        let gate = AsyncGate()
        let model = Self.model(recorder, probe: {
            await gate.wait()
            return ["alpha"]
        }, rows: [Self.row("alpha", connections: 3)])

        let probe = model.start()
        model.origin = .sample
        await gate.open()
        await probe.value

        #expect(model.step == .origin)
        #expect(model.origin == .sample)
        #expect(!model.hasScanned)
    }

    // MARK: - Steps, Back, Skip

    @Test("Origin's new connection is recorded, not run, and goes on to options; Back takes it back")
    func originNewConnection() {
        let recorder = Recorder()
        let model = Self.model(recorder)

        model.origin = .newConnection
        model.primary()

        #expect(model.step == .options)
        #expect(model.recorded == .newConnection)
        #expect(recorder.endings.isEmpty)
        #expect(model.canGoBack)

        model.back()

        #expect(model.step == .origin)
        #expect(model.recorded == nil)
        #expect(!model.canGoBack)
    }

    @Test("An origin import command ends the guide and opens that flow")
    func originCommandEnds() {
        let recorder = Recorder()
        let model = Self.model(recorder)

        model.origin = .command(.url)
        model.primary()

        #expect(recorder.endings == [.command(.url)])
        model.primary()
        #expect(recorder.endings.count == 1, "The guide ends once")
    }

    @Test("The other app card goes through import and first connection to options, Back retracing each")
    func fullPath() async throws {
        let recorder = Recorder()
        let model = Self.model(recorder, rows: [Self.row("beta", connections: 0)])

        model.origin = .command(.otherApp)
        model.primary()
        #expect(model.step == .import)
        try await waitUntil { model.hasScanned }
        #expect(model.ticked.isEmpty, "A source with no connection starts unticked")
        #expect(model.primaryTitle == String(localized: "Continue"))

        model.primary()
        #expect(model.step == .firstConnection)
        model.recorded = .sample
        model.primary()
        #expect(model.step == .options)

        model.back()
        #expect(model.step == .firstConnection)
        model.back()
        #expect(model.step == .import)
        model.back()
        #expect(model.step == .origin)
    }

    @Test("Skip on any step ends the guide by the same rule as Finish")
    func skipEnds() {
        let recorder = Recorder()
        let model = Self.model(recorder)
        model.origin = .sample
        model.primary()

        model.skip()

        #expect(recorder.endings == [.sample])
    }

    @Test("Skip on the first step with nothing recorded or imported stays")
    func skipStays() {
        let recorder = Recorder()
        let model = Self.model(recorder)

        model.skip()

        #expect(recorder.endings == [.handOff(.stay)])
    }

    @Test("The ending: a recorded choice wins, then one id opens, several select, none stays")
    func endingRule() {
        let first = UUID()
        let second = UUID()

        #expect(SetupGuideEnding.resolve(recorded: .newConnection, importedIds: [first]) == .newConnection)
        #expect(SetupGuideEnding.resolve(recorded: .sample, importedIds: [first, second]) == .sample)
        #expect(SetupGuideEnding.resolve(recorded: nil, importedIds: [first]) == .handOff(.open(first)))
        #expect(SetupGuideEnding.resolve(recorded: nil, importedIds: [first, second]) == .handOff(.select([first, second])))
        #expect(SetupGuideEnding.resolve(recorded: nil, importedIds: []) == .handOff(.stay))
        #expect(
            SetupGuideEnding.resolve(recorded: nil, importedIds: [first], origin: .fileOrLink) == .handOff(.select([first])),
            "One connection from a picked file is selected, never opened"
        )
        #expect(NavicatImporter().importOrigin == .fileOrLink)
        #expect(TablePlusImporter().importOrigin == .ownMachineOrAccount)
    }

    @Test("Closing the window stops the guide with no ending")
    func stopEndsNothing() {
        let recorder = Recorder()
        let model = Self.model(recorder)

        model.stop()
        model.skip()

        #expect(recorder.endings.isEmpty)
    }

    // MARK: - Import

    @Test("Ticked sources import one at a time in list order, and every import's ids decide the ending")
    func importQueue() async throws {
        let recorder = Recorder()
        let rows = [
            Self.row("alpha", connections: 2),
            Self.row("beta", connections: 1),
            Self.row("gamma", connections: 0),
            Self.row("delta", connections: 4, availability: .unreadable(reason: "damaged")),
        ]
        let model = Self.model(recorder, probe: { ["alpha"] }, rows: rows)
        await model.start().value
        try await waitUntil { model.hasScanned }
        #expect(model.ticked == ["alpha", "beta"])
        #expect(model.primaryTitle == String(format: String(localized: "Import %lld Connections"), 3))

        model.primary()
        try await waitUntil { Self.isReviewing(model) }
        #expect(recorder.reads == ["alpha"])
        #expect(model.isRunningImport)
        #expect(!model.canGoBack)
        let alphaReview = Self.reviewId(model)

        let first = UUID()
        model.reviewFinished(ImportOutcome(connectionIds: [first], connectionsAdded: 1))
        try await waitUntil { Self.isReviewing(model) && Self.reviewId(model) != alphaReview }
        #expect(recorder.reads == ["alpha", "beta"])
        #expect(alphaReview != nil, "Each source's review carries the id of its own read")

        let second = UUID()
        model.reviewFinished(ImportOutcome(connectionIds: [second, first], connectionsAdded: 1, connectionsReplaced: 1))

        #expect(Self.isChoosing(model))
        #expect(model.ticked.isEmpty)
        #expect(model.importedIds == [first, second])
        #expect(model.importedAppId == "alpha")
        #expect(model.results["beta"] == .imported(ImportOutcome(
            connectionIds: [second, first], connectionsAdded: 1, connectionsReplaced: 1
        )))
        #expect(model.ending == .handOff(.select([first, second])))

        model.setTicked(true, for: rows[3])
        #expect(!model.ticked.contains("delta"), "An unreadable source cannot be ticked")
    }

    @Test("A read that fails records why and moves on to the next source")
    func readFailureMovesOn() async throws {
        let recorder = Recorder()
        recorder.failing = ["alpha"]
        let model = Self.model(
            recorder,
            probe: { ["alpha"] },
            rows: [Self.row("alpha", connections: 2), Self.row("beta", connections: 1)]
        )
        await model.start().value
        try await waitUntil { model.hasScanned }

        model.primary()
        try await waitUntil { Self.isReviewing(model) }

        #expect(recorder.reads == ["alpha", "beta"])
        #expect(model.results["alpha"] == .failed("The file is damaged."))
        #expect(recorder.announcements.contains("The file is damaged."))
    }

    @Test("A cancelled review imports nothing from that source and ends the queue")
    func cancelledReview() async throws {
        let recorder = Recorder()
        let model = Self.model(recorder, probe: { ["alpha"] }, rows: [Self.row("alpha", connections: 2)])
        await model.start().value
        try await waitUntil { model.hasScanned }

        model.primary()
        try await waitUntil { Self.isReviewing(model) }
        model.skipCurrentSource()

        #expect(Self.isChoosing(model))
        #expect(model.importedIds.isEmpty)
        #expect(model.results["alpha"] == nil)
        #expect(model.ending == .handOff(.stay))
    }

    @Test("A Keychain source starts with passwords off and reads at once; turning them on asks first")
    func keychainNotice() async throws {
        let recorder = Recorder()
        let source = Self.row("alpha", connections: 2, keychain: true)
        let model = Self.model(recorder, probe: { ["alpha"] }, rows: [source])
        await model.start().value
        try await waitUntil { model.hasScanned }
        #expect(!model.request(for: source).includePasswords)

        model.setIncludePasswords(true, for: source)
        model.primary()

        guard case .notice(let notice) = model.importPhase else {
            Issue.record("Passwords from the Keychain need the notice first")
            return
        }
        #expect(notice.promptCount == 2)
        #expect(recorder.reads.isEmpty)

        model.confirmKeychainNotice()
        try await waitUntil { Self.isReviewing(model) }
        #expect(recorder.requests.first?.includePasswords == true)
    }

    // MARK: - Guarded sources

    private static func source(_ model: SetupGuideModel, _ id: String) -> ForeignSourceRow? {
        model.sources.first { $0.id == id }
    }

    @Test("The scan the probe started reads no guarded source, and counts and ticks the others")
    func probeScanSkipsGuardedReads() async throws {
        let recorder = Recorder()
        let guarded = RecordingImporter(id: "guarded", readsGuardedLocations: true)
        let open = RecordingImporter(id: "open")
        let model = Self.model(recorder, probe: { ["guarded"] }, importers: [guarded, open])

        await model.start().value
        try await waitUntil { model.hasScanned }

        #expect(guarded.calls.count(of: "isAvailable") == 0)
        #expect(guarded.calls.count(of: "inventory") == 0)
        #expect(open.calls.count(of: "inventory") == 1)
        #expect(model.sources.map { $0.availability } == [.available, .available])
        #expect(model.sources.map { $0.isCounted } == [false, true])
        #expect(model.ticked == ["open"])
    }

    @Test("Choosing the other app card reads every source, guarded or not")
    func userScanReadsGuardedSources() async throws {
        let recorder = Recorder()
        let guarded = RecordingImporter(id: "guarded", readsGuardedLocations: true)
        let open = RecordingImporter(id: "open")
        let model = Self.model(recorder, importers: [guarded, open])

        model.origin = .command(.otherApp)
        model.primary()
        try await waitUntil { model.hasScanned }

        #expect(guarded.calls.count(of: "isAvailable") == 1)
        #expect(guarded.calls.count(of: "inventory") == 1)
        #expect(open.calls.count(of: "inventory") == 1)
        #expect(model.sources.map { $0.isCounted } == [true, true])
        #expect(model.ticked == ["guarded", "open"])
    }

    @Test("Ticking an uncounted source reads it once and replaces its row with the count")
    func tickCountsOnce() async throws {
        let recorder = Recorder()
        let guarded = RecordingImporter(id: "guarded", readsGuardedLocations: true, connections: 3)
        let open = RecordingImporter(id: "open")
        let model = Self.model(recorder, probe: { ["guarded"] }, importers: [guarded, open])
        await model.start().value
        try await waitUntil { model.hasScanned }
        let uncounted = try #require(Self.source(model, "guarded"))

        model.setTicked(true, for: uncounted)
        #expect(model.ticked.contains("guarded"))
        try await waitUntil { Self.source(model, "guarded")?.isCounted == true }

        #expect(guarded.calls.count(of: "inventory") == 1)
        #expect(model.counting.isEmpty)
        #expect(Self.source(model, "guarded")?.inventory.connections == 3)
        #expect(model.ticked == ["guarded", "open"])
        #expect(model.primaryTitle == String(format: String(localized: "Import %lld Connections"), 5))

        model.setTicked(false, for: uncounted)
        model.setTicked(true, for: uncounted)
        #expect(guarded.calls.count(of: "inventory") == 1, "A counted row is never read again")
    }

    @Test("Continue waits while a ticked source is counted, and ticking it again meanwhile reads nothing more")
    func continueWaitsForCount() async throws {
        let recorder = Recorder()
        let gate = AsyncGate()
        let guarded = RecordingImporter(id: "guarded", readsGuardedLocations: true)
        let model = Self.model(recorder, probe: { ["guarded"] }, importers: [guarded], count: { importer in
            await gate.wait()
            return await ForeignSourceScanner.countedRow(for: importer)
        })
        await model.start().value
        try await waitUntil { model.hasScanned }
        let uncounted = try #require(Self.source(model, "guarded"))

        model.setTicked(true, for: uncounted)
        model.setTicked(false, for: uncounted)
        model.setTicked(true, for: uncounted)
        #expect(model.counting == ["guarded"])
        #expect(!model.canContinue)
        model.primary()
        #expect(Self.isChoosing(model), "No import starts while a count is out")
        #expect(recorder.reads.isEmpty)

        await gate.open()
        try await waitUntil { model.counting.isEmpty }

        #expect(guarded.calls.count(of: "inventory") == 1)
        #expect(model.canContinue)
    }

    @Test("A ticked source that turns out unreadable shows why and unticks; one with no connection shows 0")
    func countedSourceStates() async throws {
        let recorder = Recorder()
        let damaged = RecordingImporter(id: "damaged", readsGuardedLocations: true, isDamaged: true)
        let empty = RecordingImporter(id: "empty", readsGuardedLocations: true, connections: 0)
        let model = Self.model(recorder, probe: { ["damaged", "empty"] }, importers: [damaged, empty])
        await model.start().value
        try await waitUntil { model.hasScanned }

        for id in ["damaged", "empty"] {
            let uncounted = try #require(Self.source(model, id))
            model.setTicked(true, for: uncounted)
        }
        try await waitUntil { model.counting.isEmpty }

        #expect(Self.source(model, "damaged")?.availability == .unreadable(reason: "damaged is damaged"))
        #expect(Self.source(model, "empty")?.availability == .available)
        #expect(Self.source(model, "empty")?.isCounted == true)
        #expect(Self.source(model, "empty")?.inventory.connections == 0)
        #expect(model.ticked == ["empty"])
    }

    // MARK: - Options

    @Test("The shortcut list puts the imported app's preset first, after TablePro")
    func shortcutListing() async throws {
        let recorder = Recorder()
        let catalog = try Self.catalog()
        let model = Self.model(
            recorder,
            probe: { ["beta"] },
            rows: [Self.row("beta", connections: 1)],
            catalog: catalog
        )
        await model.start().value
        try await waitUntil { model.hasScanned }
        model.primary()
        try await waitUntil { Self.isReviewing(model) }
        model.reviewFinished(ImportOutcome(connectionIds: [UUID()], connectionsAdded: 1))
        model.primary()
        model.primary()

        let shortcuts = try #require(model.shortcuts)
        #expect(shortcuts.options == [.tablePro, .preset("beta"), .preset("alpha")])
        #expect(shortcuts.selection == .tablePro)
        #expect(!shortcuts.asksBeforeSelecting(.preset("beta")))
    }

    @Test("Customized shortcuts offer Keep Current first, ask once before they go, and come back with it")
    func keepCurrentShortcuts() throws {
        var customized = KeyboardSettings.default
        customized.setShortcut(BoundKey(keyCode: 3, command: true, shift: true, option: true), for: .formatQuery)
        let recorder = Recorder()
        let model = Self.model(recorder, keyboard: customized, catalog: try Self.catalog())
        model.origin = .newConnection
        model.primary()

        var shortcuts = try #require(model.shortcuts)
        #expect(shortcuts.options.first == .keepCurrent)
        #expect(shortcuts.selection == .keepCurrent)
        #expect(shortcuts.asksBeforeSelecting(.tablePro))
        #expect(shortcuts.settings(for: .tablePro, isSystemHotkey: { _ in false }) == .default)

        model.selectShortcut(.preset("alpha"))
        shortcuts = try #require(model.shortcuts)
        #expect(!shortcuts.asksBeforeSelecting(.tablePro), "Moving between presets replaces nothing made by hand")
        #expect(shortcuts.settings(for: .keepCurrent, isSystemHotkey: { _ in false }) == customized)

        model.back()
        model.primary()
        #expect(model.shortcuts?.original == customized, "Coming back keeps the shortcuts the guide first found")
    }

    private static func catalog() throws -> KeyboardPresetCatalog {
        let json = """
            {
              "schemaVersion": 1,
              "presets": [
                { "id": "alpha", "name": "Alpha", "platforms": ["macos"], "bindings": [] },
                { "id": "beta", "name": "Beta", "platforms": ["macos"], "bindings": [] }
              ]
            }
            """
        return try KeyboardPresetCatalog.decode(Data(json.utf8))
    }
}
