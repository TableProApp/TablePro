import Foundation
import TableProCloudAPI
import TableProImport

private struct ProbeConfig: Decodable {
    let signInEmail: String
    let legacyEmail: String
    let legacyKey: String
    let limitKey: String
    let rejectedKey: String
}

private struct LibraryConfig: Decodable {
    let teamName: String
    let teamUUID: String
    let teamKey: String
    let adminKey: String
    let memberKey: String
}

private actor CallLog {
    private(set) var lines: [String] = []

    func add(_ line: String) {
        lines.append(line)
    }
}

// The app's transport (AccountAPI.transport, what AccountServices+Live passes), writing each call to the log.
private struct LoggedTransport: ClientTransport {
    static let session = URLSession(configuration: .ephemeral)

    let log: CallLog
    let base = AccountAPI.transport(session: LoggedTransport.session)

    func send(
        _ request: HTTPRequest,
        body: HTTPBody?,
        baseURL: URL,
        operationID: String
    ) async throws -> (HTTPResponse, HTTPBody?) {
        let (response, responseBody) = try await base.send(request, body: body, baseURL: baseURL, operationID: operationID)
        let path = URL(string: baseURL.absoluteString + (request.path ?? ""))?.path ?? ""
        await log.add("\(request.method.rawValue) \(path) \(response.status.code)")
        return (response, responseBody)
    }
}

// Runs sign-in.cjs, which signs in at the account pages in headless Chrome and prints the redirect it caught.
@MainActor
private final class BrowserAuthenticator: WebAuthenticating {
    let script: String
    let email: String
    private(set) var authorizeURL: URL?
    private(set) var confirmation = ""

    init(script: String, email: String) {
        self.script = script
        self.email = email
    }

    func authenticate(url: URL, callbackScheme: String) async throws(AccountError) -> URL {
        authorizeURL = url
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["node", script, url.absoluteString, email]
        let output = Pipe()
        process.standardOutput = output
        do {
            try process.run()
        } catch {
            throw .network("node did not start: \(error.localizedDescription)")
        }
        let data = await Task.detached { output.fileHandleForReading.readDataToEndOfFile() }.value
        process.waitUntilExit()
        let lines = (String(bytes: data, encoding: .utf8) ?? "").split(separator: "\n").map(String.init)
        confirmation = lines.first { $0.hasPrefix("CONFIRM ") } ?? ""
        guard let line = lines.last(where: { $0.hasPrefix("CALLBACK ") }),
              let callback = URL(string: String(line.dropFirst("CALLBACK ".count)))
        else {
            throw .network("the browser caught no \(callbackScheme): redirect")
        }
        return callback
    }
}

@MainActor
private final class Report {
    private(set) var passed = 0
    private(set) var failed = 0

    func expect(_ condition: Bool, _ name: String, _ detail: @autoclosure () -> String = "") {
        if condition {
            passed += 1
            print("PASS \(name)")
        } else {
            failed += 1
            let shown = detail()
            print("FAIL \(name)\(shown.isEmpty ? "" : ": \(shown)")")
        }
    }
}

@main
struct AccountLocalStackProbe {
    @MainActor
    static func main() async {
        let environment = ProcessInfo.processInfo.environment
        let arguments = CommandLine.arguments.dropFirst()
        guard let configPath = arguments.first,
              let data = FileManager.default.contents(atPath: configPath),
              let config = try? JSONDecoder().decode(ProbeConfig.self, from: data),
              let libraryPath = arguments.dropFirst().first,
              let libraryData = FileManager.default.contents(atPath: libraryPath),
              let library = try? JSONDecoder().decode(LibraryConfig.self, from: libraryData),
              let script = environment["PROBE_SIGN_IN_SCRIPT"],
              let rowsScript = environment["PROBE_ROWS_SCRIPT"]
        else {
            print("usage: PROBE_SIGN_IN_SCRIPT=<sign-in.cjs> PROBE_ROWS_SCRIPT=<library-rows.cjs> probe <config.json> <library.json>")
            exit(3)
        }
        let probe = Probe(
            config: config,
            library: library,
            script: script,
            rowsScript: rowsScript,
            steps: Set((environment["PROBE_STEPS"] ?? "").split(separator: ",").map(String.init)),
            configuration: AccountConfiguration.production.overridden(by: environment)
        )
        await probe.run()
        print("\(probe.report.passed) passed, \(probe.report.failed) failed")
        exit(probe.report.failed == 0 ? 0 : 1)
    }
}

@MainActor
private final class Probe {
    let report = Report()
    private let config: ProbeConfig
    private let library: LibraryConfig
    private let script: String
    private let rowsScript: String
    private let steps: Set<String>
    private let configuration: AccountConfiguration
    private let machine = MachineDescription.current()
    private let scratch = "account-local-stack-\(UUID().uuidString)"
    private var directory: URL { FileManager.default.temporaryDirectory.appendingPathComponent(scratch, isDirectory: true) }

    init(
        config: ProbeConfig,
        library: LibraryConfig,
        script: String,
        rowsScript: String,
        steps: Set<String>,
        configuration: AccountConfiguration
    ) {
        self.config = config
        self.library = library
        self.script = script
        self.rowsScript = rowsScript
        self.steps = steps
        self.configuration = configuration
    }

    // PROBE_STEPS=account,library runs a subset; empty runs every step.
    private func runs(_ step: String) -> Bool {
        steps.isEmpty || steps.contains(step)
    }

    func run() async {
        defer {
            try? FileManager.default.removeItem(at: directory)
            UserDefaults(suiteName: scratch)?.removePersistentDomain(forName: scratch)
        }
        if runs("account") {
            await interactiveSignIn()
            await legacyKeyMigrates()
            await unknownKeyIsRefused()
            await fourthDeviceHitsTheLimit()
        }
        if runs("library") {
            await teamLibrary()
        }
    }

    // MARK: - Checks

    private func interactiveSignIn() async {
        let log = CallLog()
        let keychain = InMemoryKeychain()
        let services = services(log: log, keychain: keychain, legacyKeychain: InMemoryKeychain())
        let browser = BrowserAuthenticator(script: script, email: config.signInEmail)
        do throws(AccountError) {
            try await services.signIn(using: browser)
        } catch {
            report.expect(false, "interactive sign-in through the account pages", "\(error)")
            return
        }

        let query = browser.authorizeURL
            .flatMap { URLComponents(url: $0, resolvingAgainstBaseURL: false)?.queryItems } ?? []
        let value = { (name: String) in query.first { $0.name == name }?.value }
        report.expect(
            value("machine_name") == machine.name && value("app_version") == machine.appVersion
                && value("os_version") == machine.osVersion,
            "the authorization URL describes this Mac"
        )
        report.expect(
            browser.confirmation.contains(machine.name),
            "the confirmation screen names this Mac",
            String(browser.confirmation.prefix(300))
        )

        let entitlement = services.access.state.entitlement
        let deviceID = entitlement?.deviceID ?? "-"
        let calls = await log.lines
        report.expect(calls == [
            "POST /oauth/token authorization_code 200",
            "POST /v2/devices 201",
            "POST /oauth/token refresh_token 200",
            "POST /v2/devices/\(deviceID)/entitlement 200"
        ], "sign-in exchanges the code, registers this Mac, refreshes, then fetches", calls.joined(separator: ", "))
        report.expect(entitlement?.email == config.signInEmail, "the entitlement names the account")
        report.expect(entitlement?.machineID == machine.machineID, "the entitlement names this Mac's machine ID")
        report.expect(
            services.access.isAvailable(.iCloudSync) && services.access.check(.teamLibrary) == .notIncluded,
            "a Starter license unlocks Starter features only",
            entitlement.map { $0.features.sorted().joined(separator: ",") } ?? "no entitlement"
        )
        let token = try? await services.session.accessToken()
        report.expect(
            token?.deviceID == entitlement?.deviceID && token?.isFromLicenseKey == false,
            "the access token names the device and the interactive sign-in"
        )

        var refreshTokens = [Self.refreshToken(in: keychain)]
        for _ in 0..<2 {
            _ = try? await services.session.refreshNow()
            refreshTokens.append(Self.refreshToken(in: keychain))
        }
        report.expect(Set(refreshTokens.compactMap { $0 }).count == 3, "each refresh rotates the refresh token")

        let devices = try? await services.fetchDevices()
        report.expect(
            devices?.contains { $0.machineID == machine.machineID && $0.holdsLicense } == true,
            "GET /v2/devices lists this Mac as licensed"
        )
        do throws(AccountError) {
            let profile = try await services.fetchProfile()
            report.expect(
                profile.email == config.signInEmail && profile.memberships.isEmpty,
                "GET /v2/me names the account and no team",
                "\(profile)"
            )
        } catch {
            report.expect(false, "GET /v2/me names the account and no team", "\(error)")
        }

        await useLicenseKeyReplacesTheSession(services, log: log, keychain: keychain)
        refreshTokens.append(Self.refreshToken(in: keychain))

        await services.signOut()
        report.expect(services.access.check(.iCloudSync) == .signedOut, "sign-out leaves every feature signed out")
        let client = OAuthTokenClient(configuration: configuration) { try await URLSession.shared.data(for: $0) }
        var refusal = "refreshed"
        if let last = refreshTokens.last ?? nil {
            do throws(AccountError) {
                _ = try await client.refresh(last)
            } catch {
                refusal = "\(error)"
            }
        }
        report.expect(refusal.contains("invalid_grant"), "sign-out revokes the refresh token", refusal)
    }

    // Use License Key… on a Mac signed in interactively: the key's account takes over and the old session is revoked.
    private func useLicenseKeyReplacesTheSession(_ services: AccountServices, log: CallLog, keychain: InMemoryKeychain) async {
        let interactive = Self.refreshToken(in: keychain)
        let before = await log.lines.count
        let outcome: EntitlementRefreshState
        do throws(AccountError) {
            outcome = try await services.useLicenseKey(config.legacyKey)
        } catch {
            report.expect(false, "Use License Key signs this Mac in to the key's account", "\(error)")
            return
        }
        let entitlement = services.access.state.entitlement
        let calls = Array(await log.lines.dropFirst(before))
        report.expect(calls == [
            "POST /oauth/token \(OAuthTokenClient.tokenExchangeGrant) 200",
            "POST /oauth/revoke 200",
            "POST /v2/devices 200",
            "POST /v2/devices/\(entitlement?.deviceID ?? "-")/entitlement 200"
        ], "Use License Key exchanges the key, revokes the interactive session, registers and fetches", calls.joined(separator: ", "))
        if case .succeeded = outcome {
            report.expect(entitlement?.email == config.legacyEmail, "the entitlement names the key's account")
        } else {
            report.expect(false, "the entitlement names the key's account", "\(outcome)")
        }
        let token = try? await services.session.accessToken()
        report.expect(token?.isFromLicenseKey == true, "the new session comes from the key")
        let client = OAuthTokenClient(configuration: configuration) { try await URLSession.shared.data(for: $0) }
        var refusal = "refreshed"
        if let interactive {
            do throws(AccountError) {
                _ = try await client.refresh(interactive)
            } catch {
                refusal = "\(error)"
            }
        }
        report.expect(refusal.contains("invalid_grant"), "the replaced interactive refresh token is revoked", refusal)
    }

    private func legacyKeyMigrates() async {
        let log = CallLog()
        let legacyKeychain = InMemoryKeychain()
        legacyKeychain.writeString(config.legacyKey, forKey: LegacyLicenseStore.keychainKey)
        let services = services(log: log, keychain: InMemoryKeychain(), legacyKeychain: legacyKeychain)

        let outcome = await services.migrateLegacyKeyIfNeeded()

        report.expect(outcome == .migrated, "a stored license key migrates", "\(outcome)")
        let entitlement = services.access.state.entitlement
        let calls = await log.lines
        report.expect(calls == [
            "POST /oauth/token \(OAuthTokenClient.tokenExchangeGrant) 200",
            "POST /v2/devices 200",
            "POST /v2/devices/\(entitlement?.deviceID ?? "-")/entitlement 200"
        ], "the exchange made the device, so registering answers 200 and no refresh follows", calls.joined(separator: ", "))
        report.expect(
            legacyKeychain.readStringResult(forKey: LegacyLicenseStore.keychainKey) == .notFound,
            "the migrated key is deleted"
        )
        report.expect(entitlement?.email == config.legacyEmail, "the entitlement names the key's account")
        report.expect(services.access.isAvailable(.iCloudSync), "the migrated license unlocks its features")
        let token = try? await services.session.accessToken()
        report.expect(
            token?.isFromLicenseKey == true && token?.deviceID == entitlement?.deviceID,
            "the session comes from the key and names the device"
        )
    }

    private func unknownKeyIsRefused() async {
        let legacyKeychain = InMemoryKeychain()
        legacyKeychain.writeString(config.rejectedKey, forKey: LegacyLicenseStore.keychainKey)
        let services = services(log: CallLog(), keychain: InMemoryKeychain(), legacyKeychain: legacyKeychain)

        let outcome = await services.migrateLegacyKeyIfNeeded()

        report.expect(outcome == .keyRejected, "an unknown key is refused", "\(outcome)")
        report.expect(
            legacyKeychain.readStringResult(forKey: LegacyLicenseStore.keychainKey) == .notFound
                && services.access.check(.iCloudSync) == .signedOut,
            "the refused key is deleted and the app is signed out"
        )
    }

    private func fourthDeviceHitsTheLimit() async {
        let legacyKeychain = InMemoryKeychain()
        legacyKeychain.writeString(config.limitKey, forKey: LegacyLicenseStore.keychainKey)
        let services = services(log: CallLog(), keychain: InMemoryKeychain(), legacyKeychain: legacyKeychain)

        let outcome = await services.migrateLegacyKeyIfNeeded()

        guard case .deviceLimitReached(let holders) = services.access.state.refresh else {
            report.expect(false, "a fourth device gets device_limit_reached", "\(outcome), \(services.access.state.refresh)")
            return
        }
        report.expect(holders.count == 3, "device_limit_reached lists the 3 devices holding the slots", "\(holders.count)")
        report.expect(services.access.check(.iCloudSync) == .notIncluded, "past the device limit the app stays on Free")

        let devices = (try? await services.fetchDevices()) ?? []
        report.expect(
            devices.count == 4 && devices.contains { $0.machineID == machine.machineID && !$0.holdsLicense },
            "GET /v2/devices lists the holders and this Mac without a slot",
            "\(devices.map { "\($0.name) \($0.holdsLicense)" })"
        )
        let offline = holders.filter { $0.offlineUntil != nil }
        report.expect(
            offline.map(\.name) == ["Seeded 2"],
            "device_limit_reached gives offline_until for the holder with a valid offline file",
            "\(holders.map { "\($0.name) \($0.offlineUntil.map { "\($0)" } ?? "-")" })"
        )
        if let pinned = offline.first {
            var refusal = "removed"
            do throws(AccountError) {
                try await services.removeDevice(pinned.id)
            } catch {
                refusal = error.problemCode ?? "\(error)"
            }
            report.expect(refusal == "offline_file_active", "a holder with a valid offline file cannot be removed", refusal)
        }
        guard let holder = holders.first(where: { $0.offlineUntil == nil }) else { return }
        do throws(AccountError) {
            try await services.removeDevice(holder.id)
        } catch {
            report.expect(false, "removing a holder in place frees its slot for this Mac", "\(error)")
            return
        }
        report.expect(
            services.access.isAvailable(.iCloudSync),
            "removing a holder in place frees its slot for this Mac",
            "\(services.access.state.refresh)"
        )
    }

    // MARK: - Team library

    // An old build publishes over /v1 with the team's license key and caches its pull; the update exchanges the key,
    // takes that cache over in its first /v2 sync, pushes, a member's second device pulls, and an admin conflicts.
    private func teamLibrary() async {
        let connectionID = UUID()
        let folderID = UUID()
        let queryID = UUID()
        let directory = self.directory.appendingPathComponent("library", isDirectory: true)
        let ownerStore = store(in: directory.appendingPathComponent("owner", isDirectory: true))
        try? FileManager.default.createDirectory(at: ownerStore.directory.deletingLastPathComponent(), withIntermediateDirectories: true)

        guard await oldBuildPublishes(connectionID: connectionID, folderID: folderID, queryID: queryID, cache: ownerStore.legacyFile) else {
            return
        }
        let before = rows()
        report.expect(
            before.count == 3 && before.allSatisfy { $0.via == "v1" && $0.clientID == $0.clientID.lowercased() },
            "the old build's /v1 publish stores three items under lowercase client IDs",
            "\(before)"
        )

        let ownerLog = CallLog()
        let legacyKeychain = InMemoryKeychain()
        legacyKeychain.writeString(library.teamKey, forKey: LegacyLicenseStore.keychainKey)
        let owner = services(log: ownerLog, keychain: InMemoryKeychain(), legacyKeychain: legacyKeychain)
        let migrated = await owner.migrateLegacyKeyIfNeeded()
        report.expect(migrated == .migrated, "the update exchanges the team license key", "\(migrated)")

        let mine = TeamLibrarySync(account: owner, store: ownerStore)
        mine.loadIfNeeded()
        report.expect(
            mine.content.connections.map(\.settings.name) == ["Probe Prod"] && mine.content.queries.map(\.name) == ["Orders"],
            "the /v1 cache shows before the first /v2 pull",
            "\(mine.content)"
        )
        let synced = await mine.sync()
        report.expect(synced == .synced, "the first /v2 sync succeeds", "\(synced)")
        report.expect(
            mine.content.connections.map(\.id) == [connectionID.uuidString.lowercased()]
                && mine.content.queries.map(\.id) == [queryID.uuidString.lowercased()],
            "the first /v2 sync shows each /v1 item once, under the same client ID",
            "\(mine.content)"
        )
        report.expect(!FileManager.default.fileExists(atPath: ownerStore.legacyFile.path), "the /v1 cache is gone once the snapshot is in")
        report.expect(mine.canPublish, "the owner may publish")

        let folder = SQLFavoriteFolder(id: folderID, name: "Reports")
        let orders = SQLFavorite(id: queryID, name: "Orders", query: "select 2", folderId: folderID)
        let customers = SQLFavorite(id: UUID(), name: "Customers", query: "select * from customers")
        let queries = try? await mine.publishSavedQueries(favorites: [orders, customers], folders: [folder], to: teamID(of: mine))
        report.expect(queries == .published(2), "publishing saved queries pushes the edit and the new query", "\(String(describing: queries))")
        let renamed = TeamLibraryPublishPlan.Connection(id: connectionID, settings: Self.settings(name: "Probe Production"))
        let connections = try? await mine.publishConnections([renamed], to: teamID(of: mine))
        report.expect(connections == .published(1), "publishing the connection updates the /v1 one", "\(String(describing: connections))")
        let after = rows()
        report.expect(
            after.count == 4 && after.allSatisfy { $0.clientID == $0.clientID.lowercased() && !$0.deleted },
            "the pushes update the /v1 items in place: nothing duplicated, nothing deleted, every client ID lowercase",
            "\(after)"
        )
        report.expect(
            after.first { $0.clientID == queryID.uuidString.lowercased() }.map { $0.via == "v2" && $0.version == 2 } == true,
            "the /v1 query is now a /v2 item at version 2"
        )
        let ownerCalls = await ownerLog.lines.filter { $0.contains("/library/changes") }
        report.expect(
            ownerCalls.filter { $0.hasPrefix("POST") }.count == 2 && ownerCalls.allSatisfy { $0.hasSuffix(" 200") },
            "this Mac pushed twice and every library call answered 200",
            ownerCalls.joined(separator: ", ")
        )

        await memberPulls(customers: customers.name, teamID: teamID(of: mine), directory: directory)
        guard let admin = await adminConflicts(orders: orders, others: [customers], folder: folder, mine: mine, directory: directory) else {
            return
        }
        await folderDeletes(mine: mine, admin: admin, queryID: queryID, customers: customers, reports: folder)
    }

    private func memberPulls(customers: String, teamID: String, directory: URL) async {
        let log = CallLog()
        let member = await keyAccount(library.memberKey, log: log, machine: "Probe Second Mac")
        let theirs = TeamLibrarySync(account: member, store: store(in: directory.appendingPathComponent("member", isDirectory: true)))
        theirs.loadIfNeeded()
        _ = await theirs.sync()
        report.expect(
            Set(theirs.content.queries.map(\.name)) == ["Orders", customers]
                && theirs.content.connections.map(\.settings.name) == ["Probe Production"],
            "a member's second device pulls what this Mac pushed",
            "\(theirs.content)"
        )
        report.expect(!theirs.canPublish, "a member may only pull")
        var refusal = "published"
        do throws(TeamLibraryPublishError) {
            _ = try await theirs.publishSavedQueries(
                favorites: [SQLFavorite(id: UUID(), name: "Member's", query: "select 1")],
                folders: [],
                to: teamID
            )
        } catch {
            refusal = "\(error)"
        }
        let pushes = await log.lines.filter { $0.hasPrefix("POST") && $0.contains("/library/changes") }
        report.expect(pushes.isEmpty && refusal == "notWritable", "a member's publish is refused before anything is pushed", refusal)
    }

    private func adminConflicts(
        orders: SQLFavorite,
        others: [SQLFavorite],
        folder: SQLFavoriteFolder,
        mine: TeamLibrarySync,
        directory: URL
    ) async -> TeamLibrarySync? {
        let queryID = orders.id
        let log = CallLog()
        let admin = await keyAccount(library.adminKey, log: log, machine: "Probe Admin Mac")
        let adminStore = store(in: directory.appendingPathComponent("admin", isDirectory: true))
        let first = TeamLibrarySync(account: admin, store: adminStore)
        first.loadIfNeeded()
        _ = await first.sync()
        // The admin's edit leaves before its pull sees this Mac's next one: staged from the state it pulled.
        guard var state = adminStore.loadAll().first else {
            report.expect(false, "the admin's device holds the team's library")
            return nil
        }
        let edit = SQLFavorite(id: queryID, name: "Orders", query: "select 'admin'", folderId: nil)
        state.pending = (try? TeamLibraryPublishPlan.savedQueries(favorites: [edit], folders: [], in: state)) ?? []
        adminStore.save(state)

        var again = orders
        again.query = "select 3"
        let ours = try? await mine.publishSavedQueries(favorites: [again] + others, folders: [folder], to: teamID(of: mine))
        report.expect(ours == .published(1), "this Mac edits the query again", "\(String(describing: ours))")

        let staged = TeamLibrarySync(account: admin, store: adminStore)
        staged.loadIfNeeded()
        _ = await staged.sync()
        let conflict = staged.conflicts.first
        report.expect(
            staged.conflicts.count == 1 && conflict.flatMap { staged.current(for: $0) }?.query?.query == "select 3",
            "the admin's stale push comes back as a conflict holding this Mac's copy",
            "\(staged.conflicts)"
        )
        guard let conflict else { return nil }
        await staged.resolve(conflict, keepingMine: true)
        _ = await mine.sync()
        report.expect(
            staged.conflicts.isEmpty && mine.content.queries.first { $0.id == queryID.uuidString.lowercased() }?.query == "select 'admin'",
            "Keep Mine on the admin's device lands on this Mac's next pull",
            "\(mine.content.queries)"
        )
        return staged
    }

    // This Mac removes folders it published: Reports, which the old build published over /v1, then Archive, which holds
    // the admin's query. That query moves up and stays the admin's, so the next publish leaves it alone.
    private func folderDeletes(
        mine: TeamLibrarySync,
        admin: TeamLibrarySync,
        queryID: UUID,
        customers: SQLFavorite,
        reports: SQLFavoriteFolder
    ) async {
        let team = teamID(of: mine)
        let orders = SQLFavorite(id: queryID, name: "Orders", query: "select 'admin'", folderId: nil)
        let withoutReports = try? await mine.publishSavedQueries(favorites: [orders, customers], folders: [], to: team)
        let reportsRow = rows().first { $0.clientID == reports.id.uuidString.lowercased() }
        report.expect(
            withoutReports == .published(1) && reportsRow?.deleted == true,
            "deleting the folder the old build published over /v1 deletes it from the team",
            "\(String(describing: withoutReports)), \(String(describing: reportsRow))"
        )

        let archive = SQLFavoriteFolder(id: UUID(), name: "Archive")
        let made = try? await mine.publishSavedQueries(favorites: [orders, customers], folders: [archive], to: team)
        report.expect(made == .published(1), "this Mac publishes the folder Archive", "\(String(describing: made))")
        _ = await admin.sync()
        let adminQuery = SQLFavorite(id: UUID(), name: "AdminQ", query: "select 'adminq'", folderId: archive.id)
        let adminMade = try? await admin.publishSavedQueries(favorites: [orders, adminQuery], folders: [archive], to: team)
        report.expect(adminMade == .published(1), "the admin publishes a query into Archive", "\(String(describing: adminMade))")

        let withoutArchive = try? await mine.publishSavedQueries(favorites: [orders, customers], folders: [], to: team)
        report.expect(
            withoutArchive == .published(2),
            "deleting Archive here moves the admin's query up, then deletes the folder",
            "\(String(describing: withoutArchive))"
        )
        let again = try? await mine.publishSavedQueries(favorites: [orders, customers], folders: [], to: team)
        let adminRow = rows().first { $0.clientID == adminQuery.id.uuidString.lowercased() }
        report.expect(again == .unchanged, "publishing again with nothing changed pushes nothing", "\(String(describing: again))")
        report.expect(adminRow?.deleted == false, "the admin's moved query stays on the team", "\(String(describing: adminRow))")
        _ = await admin.sync()
        let seen = admin.content.queries.first { $0.id == adminQuery.id.uuidString.lowercased() }
        report.expect(
            seen != nil && seen?.folderName == nil,
            "the admin's device shows its query at the top level",
            "\(admin.content.queries)"
        )
    }

    // An old build: activate the key on this Mac, publish over /v1, then cache the pull as team_library.json.
    private func oldBuildPublishes(connectionID: UUID, folderID: UUID, queryID: UUID, cache: URL) async -> Bool {
        let credentials: [String: Any] = ["license_key": library.teamKey, "machine_id": machine.machineID]
        let activation = await v1("license/activate", credentials.merging([
            "machine_name": machine.name, "app_version": "0.81.0", "os_version": machine.osVersion
        ]) { $1 })
        guard activation.status == 200 else {
            report.expect(false, "an old build activates the team license key", "\(activation.status)")
            return false
        }
        let settings = (try? JSONSerialization.jsonObject(with: JSONEncoder().encode(Self.settings(name: "Probe Prod")))) ?? [:]
        let published = await v1("license/library/publish", credentials.merging([
            "connections": [["source_connection_id": connectionID.uuidString, "payload": settings]],
            "query_folders": [["client_id": folderID.uuidString, "parent_client_id": NSNull(), "name": "Reports", "sort_order": 0]],
            "queries": [[
                "client_id": queryID.uuidString, "folder_client_id": folderID.uuidString,
                "connection_client_id": connectionID.uuidString, "name": "Orders", "query": "select 1",
                "keyword": NSNull(), "sort_order": 0
            ]]
        ]) { $1 })
        report.expect(published.status == 200, "an old build publishes over /v1", "\(published.status)")
        let pulled = await v1("license/library/pull", credentials)
        report.expect(pulled.status == 200, "an old build pulls over /v1", "\(pulled.status)")
        guard published.status == 200, pulled.status == 200 else { return false }
        try? FileManager.default.createDirectory(at: cache.deletingLastPathComponent(), withIntermediateDirectories: true)
        return (try? pulled.body.write(to: cache)) != nil
    }

    private func v1(_ path: String, _ body: [String: Any]) async -> (status: Int, body: Data) {
        let base = ProcessInfo.processInfo.environment["TABLEPRO_API_URL"] ?? "http://api.localhost:5284"
        guard let url = URL(string: "\(base)/v1/\(path)"),
              let data = try? JSONSerialization.data(withJSONObject: body) else { return (0, Data()) }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.httpBody = data
        guard let (answer, response) = try? await URLSession.shared.data(for: request) else { return (0, Data()) }
        return ((response as? HTTPURLResponse)?.statusCode ?? 0, answer)
    }

    // A device of its own, signed in by exchanging a seat key, as a member's updated build would be.
    private func keyAccount(_ key: String, log: CallLog, machine name: String) async -> AccountServices {
        let machineID = (0..<32).map { _ in String(format: "%02x", UInt8.random(in: 0...255)) }.joined()
        let device = MachineDescription(machineID: machineID, name: name, appVersion: machine.appVersion, osVersion: machine.osVersion)
        let legacyKeychain = InMemoryKeychain()
        legacyKeychain.writeString(key, forKey: LegacyLicenseStore.keychainKey)
        let services = services(log: log, keychain: InMemoryKeychain(), legacyKeychain: legacyKeychain, machine: device)
        let outcome = await services.migrateLegacyKeyIfNeeded()
        report.expect(outcome == .migrated, "\(name) signs in with its seat key", "\(outcome)")
        return services
    }

    private func store(in directory: URL) -> TeamLibraryStateStore {
        TeamLibraryStateStore(
            directory: directory.appendingPathComponent("TeamLibrary", isDirectory: true),
            legacyFile: directory.appendingPathComponent("team_library.json"),
            defaults: UserDefaults(suiteName: scratch) ?? .standard
        )
    }

    private func teamID(of sync: TeamLibrarySync) -> String {
        sync.writableTeams.first?.id ?? ""
    }

    private struct Row: Decodable, CustomStringConvertible {
        let kind: String
        let clientID: String
        let version: Int
        let via: String
        let deleted: Bool

        enum CodingKeys: String, CodingKey {
            case kind, version, deleted
            case clientID = "client_id"
            case via = "updated_via"
        }

        var description: String { "\(kind) \(clientID) v\(version) \(via)\(deleted ? " deleted" : "")" }
    }

    private func rows() -> [Row] {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["node", rowsScript, library.teamUUID]
        let output = Pipe()
        process.standardOutput = output
        guard (try? process.run()) != nil else { return [] }
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (try? JSONDecoder().decode([Row].self, from: data)) ?? []
    }

    private static func settings(name: String) -> ExportableConnection {
        ExportableConnection(name: name, host: "db.internal", port: 5_432, database: "app", username: "ada", type: "PostgreSQL")
    }

    // MARK: - Helpers

    private func services(
        log: CallLog,
        keychain: InMemoryKeychain,
        legacyKeychain: InMemoryKeychain,
        machine: MachineDescription? = nil
    ) -> AccountServices {
        let machine = machine ?? self.machine
        let entitlementFile = directory.appendingPathComponent(UUID().uuidString).appendingPathComponent("entitlement.jwt")
        let defaults = UserDefaults(suiteName: scratch) ?? .standard
        return AccountServices(
            configuration: configuration,
            machine: machine,
            transport: LoggedTransport(log: log),
            send: { request in
                let form = String(bytes: request.httpBody ?? Data(), encoding: .utf8) ?? ""
                let grant = form.split(separator: "&")
                    .first { $0.hasPrefix("grant_type=") }
                    .map { String($0.dropFirst("grant_type=".count)).removingPercentEncoding ?? "" }
                let (data, response) = try await URLSession.shared.data(for: request)
                let status = (response as? HTTPURLResponse)?.statusCode ?? 0
                await log.add(["POST", request.url?.path ?? "", grant, "\(status)"].compactMap { $0 }.joined(separator: " "))
                return (data, response)
            },
            keychain: keychain,
            entitlementFile: entitlementFile,
            legacy: LegacyLicenseStore(keychain: legacyKeychain, defaults: defaults, machineID: machine.machineID) { $0.data },
            access: FeatureAccess()
        )
    }

    private static func refreshToken(in keychain: InMemoryKeychain) -> String? {
        guard case .found(let token) = keychain.readStringResult(forKey: AccountSession.refreshTokenKey) else { return nil }
        return token
    }
}
