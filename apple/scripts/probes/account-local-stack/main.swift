import Foundation
import TableProCloudAPI

private struct ProbeConfig: Decodable {
    let signInEmail: String
    let legacyEmail: String
    let legacyKey: String
    let limitKey: String
    let rejectedKey: String
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
              let script = environment["PROBE_SIGN_IN_SCRIPT"]
        else {
            print("usage: PROBE_SIGN_IN_SCRIPT=<sign-in.cjs> probe <config.json>")
            exit(3)
        }
        let probe = Probe(config: config, script: script, stack: AccountDevelopmentStack.read(environment))
        await probe.run()
        print("\(probe.report.passed) passed, \(probe.report.failed) failed")
        exit(probe.report.failed == 0 ? 0 : 1)
    }
}

@MainActor
private final class Probe {
    let report = Report()
    private let config: ProbeConfig
    private let script: String
    private let stack: AccountDevelopmentStack?
    private let machine = MachineDescription.current()
    private let scratch = "account-local-stack-\(UUID().uuidString)"
    private var directory: URL { FileManager.default.temporaryDirectory.appendingPathComponent(scratch, isDirectory: true) }

    init(config: ProbeConfig, script: String, stack: AccountDevelopmentStack?) {
        self.config = config
        self.script = script
        self.stack = stack
    }

    func run() async {
        defer {
            try? FileManager.default.removeItem(at: directory)
            UserDefaults(suiteName: scratch)?.removePersistentDomain(forName: scratch)
        }
        await interactiveSignIn()
        await legacyKeyMigrates()
        await unknownKeyIsRefused()
        await fourthDeviceHitsTheLimit()
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
        report.expect(entitlement?.email == config.signInEmail, "the entitlement names the account")
        report.expect(
            services.access.isAvailable(.iCloudSync) && services.access.check(.teamLibrary) == .notIncluded,
            "a Starter license unlocks Starter features only",
            entitlement.map { $0.features.sorted().joined(separator: ",") } ?? "no entitlement"
        )
        let refreshed = await services.refreshEntitlement()
        if case .succeeded = refreshed {
            report.expect(true, "a refresh keeps the sign-in")
        } else {
            report.expect(false, "a refresh keeps the sign-in", "\(refreshed)")
        }

        let devices = try? await services.fetchDevices()
        report.expect(
            devices?.contains { $0.isThisDevice && $0.holdsLicense } == true,
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

        await useLicenseKeyReplacesTheSession(services)

        await services.signOut()
        report.expect(services.access.check(.iCloudSync) == .signedOut, "sign-out leaves every feature signed out")
        report.expect(
            keychain.readStringResult(forKey: AccountRefreshTokenItem.production) == .notFound,
            "sign-out removes the refresh token from the Keychain"
        )
    }

    // Use License Key… on a Mac signed in interactively: the key's account takes over.
    private func useLicenseKeyReplacesTheSession(_ services: AccountServices) async {
        let outcome: EntitlementRefreshState
        do throws(AccountError) {
            outcome = try await services.useLicenseKey(config.legacyKey)
        } catch {
            report.expect(false, "Use License Key signs this Mac in to the key's account", "\(error)")
            return
        }
        if case .succeeded = outcome {
            report.expect(services.access.state.entitlement?.email == config.legacyEmail, "the entitlement names the key's account")
        } else {
            report.expect(false, "the entitlement names the key's account", "\(outcome)")
        }
    }

    private func legacyKeyMigrates() async {
        let legacyKeychain = InMemoryKeychain()
        legacyKeychain.writeString(config.legacyKey, forKey: StoredLicenseKey.keychainKey)
        let services = services(log: CallLog(), keychain: InMemoryKeychain(), legacyKeychain: legacyKeychain)

        let outcome = await services.migrateLegacyKeyIfNeeded()

        report.expect(outcome == .migrated, "a stored license key migrates", "\(outcome)")
        report.expect(
            legacyKeychain.readStringResult(forKey: StoredLicenseKey.keychainKey) == .notFound,
            "the migrated key is deleted"
        )
        report.expect(services.access.state.entitlement?.email == config.legacyEmail, "the entitlement names the key's account")
        report.expect(services.access.isAvailable(.iCloudSync), "the migrated license unlocks its features")
    }

    private func unknownKeyIsRefused() async {
        let legacyKeychain = InMemoryKeychain()
        legacyKeychain.writeString(config.rejectedKey, forKey: StoredLicenseKey.keychainKey)
        let services = services(log: CallLog(), keychain: InMemoryKeychain(), legacyKeychain: legacyKeychain)

        let outcome = await services.migrateLegacyKeyIfNeeded()

        report.expect(outcome == .keyRejected, "an unknown key is refused", "\(outcome)")
        report.expect(
            !services.hasLicenseKeyToExchange && services.access.check(.iCloudSync) == .signedOut,
            "the refused key is set aside and the app is signed out"
        )
    }

    private func fourthDeviceHitsTheLimit() async {
        let legacyKeychain = InMemoryKeychain()
        legacyKeychain.writeString(config.limitKey, forKey: StoredLicenseKey.keychainKey)
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
            devices.count == 4 && devices.contains { $0.isThisDevice && !$0.holdsLicense },
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

    // MARK: - Helpers

    // The core signs in, against the development stack, with the probe's in-memory Keychain; the Swift clients
    // write each of their calls to the log.
    private func services(
        log: CallLog,
        keychain: InMemoryKeychain,
        legacyKeychain: InMemoryKeychain,
        machine: MachineDescription? = nil
    ) -> AccountServices {
        let machine = machine ?? self.machine
        let folder = directory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let setup = AccountCoreSetup(
            accountFile: folder.appendingPathComponent("account.json"),
            legacyEntitlementFile: folder.appendingPathComponent("entitlement.jwt"),
            machineID: machine.machineID,
            policy: ManagedPolicySnapshot(),
            developmentStack: stack
        )
        let backend = CoreAccountBackend(
            config: setup.accountConfig(machine: machine),
            appVersion: machine.appVersion,
            keychain: AccountKeychain(keychain: keychain)
        )
        let services = AccountServices(
            backend: backend,
            transport: LoggedTransport(log: log),
            storedKey: StoredLicenseKey(
                keychain: legacyKeychain,
                defaults: UserDefaults(suiteName: scratch) ?? .standard,
                machineID: machine.machineID
            ),
            access: FeatureAccess(),
            sharedLinkServer: stack.flatMap { URL(string: $0.apiBase) } ?? AccountServer.production.apiBaseURL
        )
        backend.setListener(services)
        return services
    }
}
