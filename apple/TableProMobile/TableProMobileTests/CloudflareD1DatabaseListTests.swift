import Foundation
@testable import TableProMobile
import Testing

@MainActor
struct CloudflareD1DatabaseListTests {
    private struct ListFailure: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    private enum Outcome: Sendable {
        case databases([D1DatabaseInfo])
        case failure(String)
        case cancelled
    }

    // Hands out one scripted outcome per call and records the credentials each call carried.
    private actor ScriptedLoader {
        private var outcomes: [Outcome]
        private(set) var calls: [CloudflareD1Credentials] = []

        init(_ outcomes: [Outcome]) {
            self.outcomes = outcomes
        }

        func next(accountId: String, apiToken: String) throws -> [D1DatabaseInfo] {
            calls.append(CloudflareD1Credentials(accountId: accountId, apiToken: apiToken))
            let outcome = outcomes.isEmpty ? Outcome.failure("no outcome left") : outcomes.removeFirst()
            switch outcome {
            case .databases(let databases): return databases
            case .failure(let message): throw ListFailure(message: message)
            case .cancelled: throw CancellationError()
            }
        }
    }

    private let account = CloudflareD1Credentials(accountId: "b5ad7a2e0123", apiToken: "cf-token")

    private func databases(_ entries: [(name: String, uuid: String)]) throws -> [D1DatabaseInfo] {
        let objects = entries.map { ["name": $0.name, "uuid": $0.uuid] }
        return try JSONDecoder().decode([D1DatabaseInfo].self, from: JSONSerialization.data(withJSONObject: objects))
    }

    private func sample() throws -> [D1DatabaseInfo] {
        try databases([
            ("shop", "0f3c8a9e-4b1d-4c2e-9a7f-1d2e3f4a5b6c"),
            ("analytics", "7a6b5c4d-3e2f-4a1b-8c9d-0e1f2a3b4c5d")
        ])
    }

    private func makeList(_ loader: ScriptedLoader) -> CloudflareD1DatabaseList {
        CloudflareD1DatabaseList { accountId, apiToken in
            try await loader.next(accountId: accountId, apiToken: apiToken)
        }
    }

    private func names(_ list: CloudflareD1DatabaseList) -> [String] {
        list.databases.map { $0.name }
    }

    private func isIdle(_ list: CloudflareD1DatabaseList) -> Bool {
        if case .idle = list.state { return true }
        return false
    }

    private func failure(_ list: CloudflareD1DatabaseList) -> String? {
        if case .failed(let message) = list.state { return message }
        return nil
    }

    @Test("A load fetches the account's databases with its credentials and sorts them by name")
    func loadFetchesAndSorts() async throws {
        let loader = ScriptedLoader([.databases(try sample())])
        let list = makeList(loader)

        await list.load(account)

        #expect(names(list) == ["analytics", "shop"])
        #expect(await loader.calls == [account])
    }

    @Test("A second load with the same credentials does not fetch again, and new credentials do")
    func sameCredentialsDoNotRefetch() async throws {
        let other = CloudflareD1Credentials(accountId: "c0ffee000000", apiToken: "other-token")
        let loader = ScriptedLoader([.databases(try sample()), .databases(try databases([("logs", "1")]))])
        let list = makeList(loader)

        await list.load(account)
        await list.load(account)
        #expect(await loader.calls.count == 1)

        await list.load(other)
        #expect(await loader.calls == [account, other])
        #expect(names(list) == ["logs"])
    }

    @Test("A refresh fetches again and keeps the list it had when the fetch fails")
    func failedRefreshKeepsTheList() async throws {
        let loader = ScriptedLoader([
            .databases(try sample()),
            .failure("Rate limited by Cloudflare."),
            .databases(try databases([("shop", "0f3c8a9e-4b1d-4c2e-9a7f-1d2e3f4a5b6c")]))
        ])
        let list = makeList(loader)
        await list.load(account)

        await list.refresh(account)

        #expect(names(list) == ["analytics", "shop"])
        #expect(list.refreshError == "Rate limited by Cloudflare.")
        #expect(failure(list) == nil)

        await list.refresh(account)

        #expect(names(list) == ["shop"])
        #expect(list.refreshError == nil)
        #expect(await loader.calls.count == 3)
    }

    @Test("A first load that fails says why, and the next load tries again")
    func failedLoadIsRetried() async throws {
        let loader = ScriptedLoader([.failure("Authentication failed."), .databases(try sample())])
        let list = makeList(loader)

        await list.load(account)
        #expect(failure(list) == "Authentication failed.")

        await list.load(account)
        #expect(names(list) == ["analytics", "shop"])
        #expect(await loader.calls.count == 2)
    }

    @Test("A cancelled load is not a failure, and the next visit loads again")
    func cancelledLoadIsNotAFailure() async throws {
        let loader = ScriptedLoader([.cancelled, .databases(try sample())])
        let list = makeList(loader)

        await list.load(account)
        #expect(isIdle(list))

        await list.load(account)
        #expect(names(list) == ["analytics", "shop"])
    }

    @Test("Leaving the picker mid-load cancels it without a failure")
    func cancelledTaskIsNotAFailure() async throws {
        let gate = TestGate()
        let fetched = try sample()
        let list = CloudflareD1DatabaseList { _, _ in
            await gate.enter()
            try Task.checkCancellation()
            return fetched
        }

        let visit = Task { await list.load(account) }
        await gate.waitUntilEntered()
        visit.cancel()
        await gate.open()
        await visit.value

        #expect(isIdle(list))
        #expect(list.databases.isEmpty)
    }

    @Test("A cancelled refresh keeps the list and reports nothing")
    func cancelledRefreshKeepsTheList() async throws {
        let loader = ScriptedLoader([.databases(try sample()), .cancelled])
        let list = makeList(loader)
        await list.load(account)

        await list.refresh(account)

        #expect(names(list) == ["analytics", "shop"])
        #expect(list.refreshError == nil)
    }

    @Test("A list for credentials the user has since replaced is dropped when it arrives")
    func staleListIsDropped() async throws {
        let gate = TestGate()
        let stale = try databases([("old", "1")])
        let current = try databases([("new", "2")])
        let list = CloudflareD1DatabaseList { accountId, _ in
            if accountId == "old-account" {
                await gate.enter()
                return stale
            }
            return current
        }

        let first = Task { await list.load(CloudflareD1Credentials(accountId: "old-account", apiToken: "t")) }
        await gate.waitUntilEntered()
        await list.load(account)
        await gate.open()
        await first.value

        #expect(names(list) == ["new"])
    }

    @Test("Without an Account ID or token nothing is fetched")
    func incompleteCredentialsFetchNothing() async {
        let loader = ScriptedLoader([])
        let list = makeList(loader)

        await list.load(CloudflareD1Credentials(accountId: "", apiToken: "cf-token"))
        await list.load(CloudflareD1Credentials(accountId: "b5ad7a2e0123", apiToken: ""))

        #expect(isIdle(list))
        #expect(await loader.calls.isEmpty)
    }

    @Test("Search matches a name or a UUID, ignoring case")
    func searchMatchesNameOrUUID() async throws {
        let list = makeList(ScriptedLoader([.databases(try sample())]))
        await list.load(account)

        #expect(list.databases(matching: "SHO").map { $0.name } == ["shop"])
        #expect(list.databases(matching: "7A6B5C4D").map { $0.name } == ["analytics"])
        #expect(list.databases(matching: "  ").count == 2)
    }

    @Test("A typed name or UUID is offered only when valid and not already listed")
    func typedDatabaseOffer() async throws {
        let list = makeList(ScriptedLoader([.databases(try sample())]))
        await list.load(account)

        #expect(list.typedDatabase(in: " staging-db_2 ") == "staging-db_2")
        #expect(list.typedDatabase(in: "11111111-2222-4333-8444-555555555555") == "11111111-2222-4333-8444-555555555555")
        #expect(list.typedDatabase(in: "shop") == nil)
        #expect(list.typedDatabase(in: "0F3C8A9E-4B1D-4C2E-9A7F-1D2E3F4A5B6C") == nil)
        #expect(list.typedDatabase(in: "my db") == nil)
        #expect(list.typedDatabase(in: "-shop") == nil)
        #expect(list.typedDatabase(in: "shop/../x") == nil)
        #expect(list.typedDatabase(in: "") == nil)
    }

    @Test("A typed value is still offered when the list could not load")
    func typedDatabaseAfterFailure() async {
        let list = makeList(ScriptedLoader([.failure("offline")]))
        await list.load(account)

        #expect(list.typedDatabase(in: "shop") == "shop")
        #expect(list.listedDatabase("shop") == nil)
    }

    @Test("A stored UUID finds its listed database, so the picker marks it")
    func storedUUIDFindsItsDatabase() async throws {
        let list = makeList(ScriptedLoader([.databases(try sample())]))
        await list.load(account)

        #expect(list.listedDatabase("0f3c8a9e-4b1d-4c2e-9a7f-1d2e3f4a5b6c")?.name == "shop")
        #expect(list.listedDatabase("analytics")?.name == "analytics")
    }
}
