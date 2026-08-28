//
//  ObjectCopySession.swift
//  TablePro
//
//  The state of one copy, from the sheet opening to the result.
//
//  It holds no driver and performs no I/O of its own: the catalog reads, the
//  planner resolves and the runner writes, the same split `CompareSyncSession`
//  keeps with `CompareRunner`.
//
//  There are two steps rather than one because the issue asks for the script to
//  be shown before anything runs, and a plan cannot be built without reaching
//  both databases. Configuring is free; reviewing costs one round of reads.
//

import Foundation
import Observation
import os
import TableProPluginKit

/// Which of the sidebar's three commands opened the sheet.
internal enum ObjectCopyMode: Hashable, Sendable {
    /// Copy the chosen objects into a database that already exists, anywhere.
    case copyTo
    /// Copy a whole database into a new one on the same connection.
    case duplicateDatabase
}

internal enum ObjectCopyStep: Hashable {
    case configuring
    case reviewing
    case copying
    case finished
}

/// Whether the destination's create-database options have arrived. A failure is kept as a failure:
/// the request that follows needs the values, so "not loaded yet" and "cannot be loaded" are both
/// reasons to hold Continue rather than to send an empty request.
internal enum ObjectCopyFormState: Hashable {
    case loading
    case ready
    case unsupported
    case failed(String)
}

@MainActor
@Observable
internal final class ObjectCopySession {
    nonisolated private static let logger = Logger(subsystem: "com.TablePro", category: "ObjectCopySession")

    // MARK: - Fixed at launch

    internal let mode: ObjectCopyMode
    internal let source: DatabaseEndpoint
    internal let sourceConnection: DatabaseConnection

    // MARK: - Choices

    internal var target: DatabaseEndpoint?
    internal var newDatabaseName = ""
    internal var newDatabaseValues: [String: String] = [:]
    internal var createDatabaseForm: CreateDatabaseFormSpec?
    internal var createDatabaseFormState: ObjectCopyFormState = .loading
    internal var content: ObjectCopyContent = .structureAndData
    internal var existingPolicy: ObjectCopyExistingPolicy = .skip
    internal var errorHandling: ImportErrorHandling = .stopAndRollback
    internal var searchText = ""

    // MARK: - Catalog

    internal var availableObjects: [ObjectCopySelection] = []
    internal var selectedObjectIds: Set<String> = []
    internal var isLoadingObjects = true
    internal var catalogError: String?

    // MARK: - Run

    internal var step: ObjectCopyStep = .configuring
    internal var plan: ObjectCopyPlan?
    internal var progress: Progress?
    internal var copiedRows = 0
    internal var currentObject = ""
    internal var result: ObjectCopyRunResult?
    internal var errorMessage: String?
    @ObservationIgnored internal var runTask: Task<Void, Never>?

    internal init(
        mode: ObjectCopyMode,
        source: DatabaseEndpoint,
        sourceConnection: DatabaseConnection,
        preselected: [ObjectCopySelection]
    ) {
        self.mode = mode
        self.source = source
        self.sourceConnection = sourceConnection
        self.pendingPreselection = preselected
        if mode == .duplicateDatabase {
            self.newDatabaseName = Self.suggestedCopyName(for: source.databaseLabel)
        }
    }

    @ObservationIgnored private let pendingPreselection: [ObjectCopySelection]

    // MARK: - Naming

    /// The Finder's own convention for a duplicate, which is what a user expects to see prefilled.
    internal static func suggestedCopyName(for name: String) -> String {
        guard !name.isEmpty else { return "" }
        return "\(name)_copy"
    }

    // MARK: - Derived

    internal var title: String {
        switch mode {
        case .copyTo: return String(localized: "Copy To")
        case .duplicateDatabase: return String(localized: "Duplicate Database")
        }
    }

    internal var selectedObjects: [ObjectCopySelection] {
        availableObjects.filter { selectedObjectIds.contains($0.id) }
    }

    internal var filteredObjects: [ObjectCopySelection] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !query.isEmpty else { return availableObjects }
        return availableObjects.filter { $0.name.lowercased().contains(query) }
    }

    internal var isBusy: Bool {
        step == .copying
    }

    /// Why Copy is unavailable, or nil when it is. Spelled as a reason rather than a bool so the
    /// sheet can say what is missing instead of leaving a dead button.
    internal var reviewDisabledReason: String? {
        if selectedObjectIds.isEmpty {
            return String(localized: "Choose at least one object to copy.")
        }
        switch mode {
        case .copyTo:
            guard let target else { return String(localized: "Choose where to copy to.") }
            if let reason = ObjectCopyEligibility.targetRefusal(target) { return reason }
            if let reason = ObjectCopyEligibility.sameObjectRefusal(source: source, target: target) {
                return reason
            }
            if let reason = ObjectCopyEligibility.engineRefusal(
                from: source.databaseType, to: target.databaseType
            ) {
                return reason
            }
        case .duplicateDatabase:
            let trimmed = newDatabaseName.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return String(localized: "Name the new database.") }
            if trimmed.caseInsensitiveCompare(source.database) == .orderedSame {
                return String(localized: "Choose a name the source does not already have.")
            }
            switch createDatabaseFormState {
            case .loading:
                return String(localized: "Reading this connection's database options…")
            case .unsupported:
                return String(
                    format: String(localized: "%@ cannot create a database."), source.databaseType.rawValue
                )
            case .failed(let message):
                return message
            case .ready:
                break
            }
        }
        return nil
    }

    internal var request: ObjectCopyRequest? {
        guard reviewDisabledReason == nil else { return nil }
        let destination: ObjectCopyDestination
        switch mode {
        case .copyTo:
            guard let target else { return nil }
            destination = .existing(target)
        case .duplicateDatabase:
            /// A field the form is hiding holds a stale answer rather than a chosen one, so it
            /// never reaches `CREATE DATABASE`.
            let values = createDatabaseForm.map {
                CreateDatabaseFormRules.submissionValues(from: newDatabaseValues, spec: $0)
            } ?? newDatabaseValues
            destination = .newDatabase(
                base: source,
                name: newDatabaseName.trimmingCharacters(in: .whitespacesAndNewlines),
                values: values
            )
        }
        return ObjectCopyRequest(
            source: source,
            destination: destination,
            objects: selectedObjects,
            content: content,
            existingPolicy: existingPolicy,
            errorHandling: errorHandling,
            wrapEachTableInTransaction: true
        )
    }

    // MARK: - Catalog

    internal func loadObjects(catalog: ObjectCopyCatalog = ObjectCopyCatalog()) async {
        isLoadingObjects = true
        catalogError = nil
        defer { isLoadingObjects = false }
        do {
            let found = try await catalog.objects(in: source, connection: sourceConnection)
            availableObjects = found.sorted { lhs, rhs in
                guard lhs.kind == rhs.kind else { return lhs.kind.rawValue < rhs.kind.rawValue }
                return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
            }
            applyPreselection()
        } catch {
            catalogError = error.localizedDescription
            availableObjects = []
        }
    }

    /// A right-click on one table preselects that table. A right-click on a database preselects
    /// everything in it, which is what "copy this database" means.
    ///
    /// Matched on kind and name rather than on the name alone, and never falling back to the whole
    /// catalog: the first version preselected every object sharing a name with the clicked one, and
    /// when it matched nothing it selected the entire database. Followed by Replace, that acted on
    /// objects the user had not chosen.
    private func applyPreselection() {
        guard !pendingPreselection.isEmpty else {
            selectedObjectIds = Set(availableObjects.map(\.id))
            return
        }
        let wanted = Set(pendingPreselection.map { Self.preselectionKey($0) })
        selectedObjectIds = Set(
            availableObjects
                .filter { wanted.contains(Self.preselectionKey($0)) }
                .map(\.id)
        )
    }

    /// The sidebar knows the kind and the name; it does not know a routine's argument list. So the
    /// match uses what both sides can agree on and leaves everything else unselected.
    private static func preselectionKey(_ selection: ObjectCopySelection) -> String {
        "\(selection.kind.rawValue)\u{1F}\(selection.name.lowercased())"
    }

    /// The catalog read is the only caller in the app, and it is the one thing a test cannot drive
    /// without a live connection.
    internal func applyPreselectionForTesting() {
        applyPreselection()
    }

    /// The form is not decoration. MySQL's `createDatabase` requires a character set, so starting a
    /// duplicate before this answers, or after it failed, sent a request with no values that was
    /// guaranteed to be refused. A nil spec is also how a driver says it cannot create a database
    /// at all, which is what keeps Duplicate off DuckDB, Trino and Teradata.
    internal func loadCreateDatabaseForm(catalog: ObjectCopyCatalog = ObjectCopyCatalog()) async {
        guard mode == .duplicateDatabase, createDatabaseFormState == .loading else { return }
        do {
            guard let spec = try await catalog.createDatabaseForm(for: source, connection: sourceConnection)
            else {
                createDatabaseFormState = .unsupported
                return
            }
            createDatabaseForm = spec
            newDatabaseValues = CreateDatabaseFormRules.initialValues(for: spec)
            createDatabaseFormState = .ready
        } catch {
            createDatabaseFormState = .failed(error.localizedDescription)
        }
    }

    internal func toggle(_ selection: ObjectCopySelection) {
        if selectedObjectIds.contains(selection.id) {
            selectedObjectIds.remove(selection.id)
        } else {
            selectedObjectIds.insert(selection.id)
        }
    }

    /// Adds what is on screen rather than replacing the whole selection, so a search that is hiding
    /// already-ticked objects cannot silently untick them. None subtracts only the visible ones for
    /// the same reason.
    internal func selectAll() {
        selectedObjectIds.formUnion(Set(filteredObjects.map(\.id)))
    }

    internal func selectNone() {
        selectedObjectIds.subtract(Set(filteredObjects.map(\.id)))
    }

    // MARK: - Review

    /// The step moves before the reads start, not after they finish. Leaving the sheet on its
    /// configuring step while this ran let the user change the target and press Continue again,
    /// and the plan that eventually arrived was the one built for the settings they had moved off.
    internal func review(planner: ObjectCopyPlanner = ObjectCopyPlanner()) {
        guard let request else { return }
        errorMessage = nil
        plan = nil
        runTask?.cancel()
        step = .reviewing
        runTask = Task { [weak self] in
            guard let self else { return }
            do {
                let built = try await planner.plan(request)
                guard !Task.isCancelled else { return }
                guard !built.isEmpty else {
                    self.errorMessage = String(
                        localized: "Nothing is left to copy once the target is taken into account."
                    )
                    self.step = .configuring
                    return
                }
                self.plan = built
            } catch is CancellationError {
                return
            } catch {
                self.errorMessage = error.localizedDescription
                self.step = .configuring
            }
        }
    }

    internal func backToConfiguring() {
        runTask?.cancel()
        runTask = nil
        plan = nil
        errorMessage = nil
        step = .configuring
    }

    // MARK: - Run

    internal func start(runner: ObjectCopyRunner = ObjectCopyRunner()) {
        guard let plan else { return }
        errorMessage = nil
        copiedRows = 0
        currentObject = ""
        let runProgress = Progress(totalUnitCount: Int64(max(plan.estimatedRowTotal, 0)))
        runProgress.isCancellable = true
        progress = runProgress
        step = .copying

        let reporter = ObjectCopyProgress(progress: runProgress)
        runTask = Task { [weak self] in
            guard let self else { return }
            let started = ContinuousClock.Instant.now
            do {
                let outcome = try await runner.run(plan, progress: reporter)
                self.result = outcome
                self.step = .finished
                self.report(outcome, plan: plan, startedAt: started)
            } catch is CancellationError {
                self.step = .reviewing
            } catch {
                self.errorMessage = error.localizedDescription
                self.step = .reviewing
            }
            self.progress = nil
        }

        observe(runProgress)
    }

    internal func cancel() {
        progress?.cancel()
        runTask?.cancel()
    }

    @ObservationIgnored private var observations: [NSKeyValueObservation] = []

    private func observe(_ runProgress: Progress) {
        observations.forEach { $0.invalidate() }
        observations = [
            runProgress.observe(\.completedUnitCount) { [weak self] observed, _ in
                let count = Int(observed.completedUnitCount)
                Task { @MainActor [weak self] in self?.copiedRows = count }
            },
            runProgress.observe(\.localizedDescription) { [weak self] observed, _ in
                let name = observed.localizedDescription ?? ""
                Task { @MainActor [weak self] in self?.currentObject = name }
            }
        ]
    }

    deinit {
        observations.forEach { $0.invalidate() }
    }

    private func report(_ outcome: ObjectCopyRunResult, plan: ObjectCopyPlan, startedAt: ContinuousClock.Instant) {
        let result: OperationOutcome
        if outcome.cancelled {
            result = .cancelled
        } else if let failure = outcome.firstError {
            result = .failed(reason: failure)
        } else {
            /// Rows only. `statementCount` reads out as "Ran N statements", and a copy's object
            /// count is not a statement count: one table can be a DROP, a CREATE and a thousand
            /// INSERTs.
            result = .succeeded(OperationSummary(rowsAffected: outcome.rowsCopied))
        }
        OperationCompletionReporter.shared.report(OperationCompletion(
            kind: .objectCopy,
            owner: .connection(plan.request.target.connectionId),
            connectionId: plan.request.target.connectionId,
            connectionName: plan.request.target.connectionName,
            databaseName: plan.request.target.database,
            elapsed: startedAt.duration(to: .now),
            outcome: result
        ))
    }
}
