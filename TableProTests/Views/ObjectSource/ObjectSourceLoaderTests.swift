//
//  ObjectSourceLoaderTests.swift
//  TableProTests
//
//  A connection switch re-parents the source tab and SwiftUI restarts its `.task`. The loader keeps
//  what it loaded across that, and still fetches when nothing usable is on screen.
//

import Foundation
@testable import TablePro
import TableProPluginKit
import Testing

@MainActor
struct ObjectSourceLoaderTests {
    private let functionRef = DatabaseObjectRef(
        kind: .function,
        name: "total",
        database: "shop",
        schema: "public",
        argumentSignature: "(integer)"
    )
    private let definition = "CREATE FUNCTION public.total(integer) RETURNS integer AS $$ SELECT 1 $$ LANGUAGE sql"
    private let fetchCall = "fetchRoutineDDL:total"

    private func makeLoader(
        _ driver: SourceDefinitionStubDriver
    ) -> (loader: ObjectSourceLoader, metadata: ScriptedSourceMetadata) {
        let adapter = PluginDriverAdapter(
            connection: TestFixtures.makeConnection(type: .postgresql),
            pluginDriver: driver
        )
        let metadata = ScriptedSourceMetadata(driver: adapter)
        let loader = ObjectSourceLoader(connectionId: UUID(), objectRef: functionRef, metadata: metadata)
        return (loader, metadata)
    }

    private func isLoaded(_ loader: ObjectSourceLoader) -> Bool {
        if case .loaded = loader.state { return true }
        return false
    }

    @Test("An appearance after a load keeps the source and sends no second fetch")
    func appearanceAfterLoadKeepsSource() async {
        let driver = SourceDefinitionStubDriver()
        driver.routineDDL["total"] = .success(definition)
        let (loader, _) = makeLoader(driver)

        await loader.load()
        await loader.loadIfNeeded()

        #expect(isLoaded(loader))
        #expect(loader.source == definition)
        #expect(driver.recordedCalls == [fetchCall])
    }

    @Test("The first appearance fetches the source")
    func firstAppearanceFetches() async {
        let driver = SourceDefinitionStubDriver()
        driver.routineDDL["total"] = .success(definition)
        let (loader, _) = makeLoader(driver)

        await loader.loadIfNeeded()

        #expect(loader.source == definition)
        #expect(driver.recordedCalls == [fetchCall])
    }

    @Test("Reload still fetches after the source is loaded")
    func reloadStillFetches() async {
        let driver = SourceDefinitionStubDriver()
        driver.routineDDL["total"] = .success(definition)
        let (loader, _) = makeLoader(driver)
        await loader.loadIfNeeded()

        let altered = "CREATE FUNCTION public.total(integer) RETURNS integer AS $$ SELECT 2 $$ LANGUAGE sql"
        driver.routineDDL["total"] = .success(altered)
        await loader.load(isRefresh: true)

        #expect(loader.source == altered)
        #expect(driver.recordedCalls == [fetchCall, fetchCall])
    }

    @Test("A failed load is retried on the next appearance")
    func failedLoadIsRetried() async {
        let driver = SourceDefinitionStubDriver()
        driver.routineDDL["total"] = .failure(DefinitionReadStubError(message: "server unreachable"))
        let (loader, _) = makeLoader(driver)

        await loader.loadIfNeeded()
        guard case .failed = loader.state else {
            Issue.record("A failed fetch did not leave the loader failed")
            return
        }

        driver.routineDDL["total"] = .success(definition)
        await loader.loadIfNeeded()

        #expect(loader.source == definition)
        #expect(driver.recordedCalls == [fetchCall, fetchCall])
    }

    @Test("A cancelled load is not recorded as loaded, so the next appearance fetches")
    func cancelledLoadIsRetried() async {
        let driver = SourceDefinitionStubDriver()
        driver.routineDDL["total"] = .success(definition)
        let (loader, metadata) = makeLoader(driver)
        metadata.cancelsNextRead = true

        await loader.loadIfNeeded()

        #expect(!isLoaded(loader))
        #expect(driver.recordedCalls.isEmpty)

        await loader.loadIfNeeded()

        #expect(loader.source == definition)
        #expect(driver.recordedCalls == [fetchCall])
    }
}

/// Throws `CancellationError` once on request, the way a metadata read does when the task that
/// asked for it was cancelled before the driver ran.
@MainActor
private final class ScriptedSourceMetadata: ScopedMetadataProviding {
    private let driver: DatabaseDriver
    var cancelsNextRead = false

    init(driver: DatabaseDriver) {
        self.driver = driver
    }

    func withMetadataDriver<T: Sendable>(
        scope: DatabaseScope,
        workload: MetadataConnectionPool.Workload,
        _ body: @Sendable @escaping (DatabaseDriver) async throws -> T
    ) async throws -> T {
        if cancelsNextRead {
            cancelsNextRead = false
            throw CancellationError()
        }
        return try await body(driver)
    }

    func browseScope(for connectionId: UUID) -> DatabaseScope? { nil }
}
