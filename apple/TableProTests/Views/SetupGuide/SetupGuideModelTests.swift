//
//  SetupGuideModelTests.swift
//  TableProTests
//

import Foundation
@testable import TablePro
import TableProImport
import TableProTestSupport
import Testing
import UniformTypeIdentifiers

@MainActor
struct SetupGuideModelTests {
    private struct StubImporter: ForeignAppImporter {
        let id: String
        var readsPasswordsFromKeychain = false
        var fileTypes: [UTType]?
        var displayName: String { id }
        var importFileTypes: [UTType]? { fileTypes }
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
        var scans = 0
        var failing: Set<String> = []
    }

    private static func row(
        _ id: String,
        connections: Int,
        availability: ForeignSourceAvailability = .available,
        keychain: Bool = false,
        picksFile: Bool = false
    ) -> ForeignSourceRow {
        ForeignSourceRow(
            importer: StubImporter(id: id, readsPasswordsFromKeychain: keychain, fileTypes: picksFile ? [.data] : nil),
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
        probe: @escaping @Sendable () async -> [any ForeignAppImporter] = { [] },
        rows: [ForeignSourceRow] = [],
        importers: [any ForeignAppImporter]? = nil,
        keyboard: KeyboardSettings = .default,
        catalog: KeyboardPresetCatalog? = nil,
        clock: any Clock<Duration> = ContinuousClock(),
        readGate: AsyncGate? = nil
    ) -> SetupGuideModel {
        let model = SetupGuideModel(dependencies: SetupGuideModel.Dependencies(
            probe: probe,
            scan: {
                await MainActor.run { recorder.scans += 1 }
                guard let importers else { return rows }
                return await ForeignSourceScanner.scan(importers)
            },
            read: { importer, request in
                recorder.reads.append(importer.id)
                recorder.requests.append(request)
                await readGate?.wait()
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

    // Continue on the other app card is the only way into import.
    private static func openImport(_ model: SetupGuideModel) async throws {
        model.choose(.command(.otherApp))
        model.primary()
        try await waitUntil { model.hasScanned }
    }

    // MARK: - First step

    @Test("Apps the probe finds select the other app card and are named on origin; nothing is read until Continue")
    func probeSelectsOtherAppOnOrigin() async throws {
        let recorder = Recorder()
        let alpha = RecordingImporter(id: "alpha")
        let beta = RecordingImporter(id: "beta")
        let model = Self.model(recorder, probe: { [alpha, beta] }, importers: [alpha, beta])

        await model.start().value

        #expect(model.step == .origin)
        #expect(!model.canGoBack)
        #expect(model.origin == .command(.otherApp))
        #expect(model.foundApps == ["Alpha", "Beta"])
        #expect(SetupGuideOriginStep.detail(for: .command(.otherApp), foundApps: model.foundApps) == String(
            format: String(localized: "Found on this Mac: %@"),
            ListFormatter.localizedString(byJoining: ["Alpha", "Beta"])
        ))
        #expect(recorder.scans == 0)
        #expect(alpha.calls.count(of: "inventory") == 0)

        model.primary()

        #expect(model.step == .import)
        try await waitUntil { model.hasScanned }
        #expect(recorder.scans == 1)
        #expect(alpha.calls.count(of: "inventory") == 1)
        #expect(beta.calls.count(of: "inventory") == 1)
        #expect(model.ticked == ["alpha", "beta"])
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
            return [StubImporter(id: "alpha")]
        }, clock: clock)

        let probe = model.start()
        await clock.waitUntilSleeping()
        clock.advance(by: .seconds(2))
        try await waitUntil { !model.isWaitingForProbe }
        await gate.open()
        await probe.value

        #expect(model.step == .origin)
        #expect(model.origin == .newConnection, "An answer nobody waited for selects nothing")
        #expect(model.foundApps.isEmpty)
    }

    @Test("A choice made while the probe runs stays; the probe only names what it found")
    func choiceDuringProbeWins() async {
        let recorder = Recorder()
        let gate = AsyncGate()
        let model = Self.model(recorder, probe: {
            await gate.wait()
            return [StubImporter(id: "alpha")]
        })

        let probe = model.start()
        model.choose(.sample)
        await gate.open()
        await probe.value

        #expect(model.step == .origin)
        #expect(model.origin == .sample)
        #expect(model.foundApps == ["alpha"])
        #expect(recorder.scans == 0)
    }

    @Test("Continue on the default card is a choice too, so Back finds it as the user left it")
    func continueBeforeProbeWins() async {
        let recorder = Recorder()
        let gate = AsyncGate()
        let model = Self.model(recorder, probe: {
            await gate.wait()
            return [StubImporter(id: "alpha")]
        })

        let probe = model.start()
        model.primary()
        model.back()
        await gate.open()
        await probe.value

        #expect(model.step == .origin)
        #expect(model.origin == .newConnection)
    }

    // MARK: - Steps, Back, Skip

    @Test("Origin's new connection is recorded, not run, and goes on to options; Back takes it back")
    func originNewConnection() {
        let recorder = Recorder()
        let model = Self.model(recorder)

        model.choose(.newConnection)
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

        model.choose(.command(.url))
        model.primary()

        #expect(recorder.endings == [.command(.url)])
        model.primary()
        #expect(recorder.endings.count == 1, "The guide ends once")
    }

    @Test("The other app card goes through import and first connection to options, Back retracing each")
    func fullPath() async throws {
        let recorder = Recorder()
        let model = Self.model(recorder, rows: [Self.row("beta", connections: 0)])

        model.choose(.command(.otherApp))
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
        model.choose(.sample)
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
        let model = Self.model(recorder, rows: rows)
        try await Self.openImport(model)
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
        let model = Self.model(recorder, rows: [Self.row("alpha", connections: 2), Self.row("beta", connections: 1)])
        try await Self.openImport(model)

        model.primary()
        try await waitUntil { Self.isReviewing(model) }

        #expect(recorder.reads == ["alpha", "beta"])
        #expect(model.results["alpha"] == .failed("The file is damaged."))
        #expect(recorder.announcements.contains("The file is damaged."))
    }

    @Test("A cancelled review imports nothing from that source and ends the queue")
    func cancelledReview() async throws {
        let recorder = Recorder()
        let model = Self.model(recorder, rows: [Self.row("alpha", connections: 2)])
        try await Self.openImport(model)

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
        let model = Self.model(recorder, rows: [source])
        try await Self.openImport(model)
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

    @Test("The current source follows the queue through its notice, read, review and file prompt")
    func currentSourceFollowsTheQueue() async throws {
        let recorder = Recorder()
        let gate = AsyncGate()
        let keychain = Self.row("alpha", connections: 2, keychain: true)
        let file = Self.row("export", connections: 0, picksFile: true)
        let model = Self.model(recorder, rows: [keychain, file], readGate: gate)
        try await Self.openImport(model)
        #expect(model.currentSourceId == nil)
        model.setIncludePasswords(true, for: keychain)
        model.setTicked(true, for: file)

        model.primary()
        guard case .notice = model.importPhase else {
            Issue.record("Passwords from the Keychain need the notice first")
            return
        }
        #expect(model.currentSourceId == "alpha")

        model.confirmKeychainNotice()
        guard case .reading = model.importPhase else {
            Issue.record("The notice's Continue starts the read")
            return
        }
        #expect(model.currentSourceId == "alpha")

        await gate.open()
        try await waitUntil { Self.isReviewing(model) }
        #expect(model.currentSourceId == "alpha")

        model.reviewFinished(ImportOutcome(connectionIds: [UUID()], connectionsAdded: 1))
        guard case .pickingFile = model.importPhase else {
            Issue.record("A source that picks a file asks for it next")
            return
        }
        #expect(model.currentSourceId == "export")

        model.skipCurrentSource()
        #expect(Self.isChoosing(model))
        #expect(model.currentSourceId == nil)
    }

    // MARK: - Options

    @Test("The shortcut list puts the imported app's preset first, after TablePro")
    func shortcutListing() async throws {
        let recorder = Recorder()
        let catalog = try Self.catalog()
        let model = Self.model(recorder, rows: [Self.row("beta", connections: 1)], catalog: catalog)
        try await Self.openImport(model)
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
        model.choose(.newConnection)
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

    @Test("Options names a recorded choice on its primary, and Done when nothing opens")
    func optionsPrimaryNamesTheRecordedChoice() {
        let recorder = Recorder()
        let model = Self.model(recorder)
        model.choose(.newConnection)
        model.primary()
        #expect(model.step == .options)

        #expect(model.primaryTitle == String(localized: "Add Connection"))
        model.recorded = .sample
        #expect(model.primaryTitle == String(localized: "Open Sample"))
        model.recorded = nil
        #expect(model.primaryTitle == String(localized: "Done"))
    }

    @Test("Options names what the import hands off: one connection opens, several are shown", arguments: [1, 2])
    func optionsPrimaryNamesTheHandoff(imported: Int) async throws {
        let recorder = Recorder()
        let model = Self.model(recorder, rows: [Self.row("alpha", connections: imported)])
        try await Self.openImport(model)
        model.primary()
        try await waitUntil { Self.isReviewing(model) }
        let ids = (0..<imported).map { _ in UUID() }
        model.reviewFinished(ImportOutcome(connectionIds: ids, connectionsAdded: imported))
        model.primary()
        model.primary()
        #expect(model.step == .options)

        #expect(model.primaryTitle == (imported == 1
            ? String(localized: "Open Connection")
            : String(localized: "Show Connections")))
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
