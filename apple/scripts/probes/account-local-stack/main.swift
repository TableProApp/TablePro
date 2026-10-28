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

// URLSession under the generated client, while AccountServices+Live ships no transport.
private struct ProbeTransport: ClientTransport {
    let log: CallLog

    func send(
        _ request: HTTPRequest,
        body: HTTPBody?,
        baseURL: URL,
        operationID: String
    ) async throws -> (HTTPResponse, HTTPBody?) {
        guard let url = URL(string: baseURL.absoluteString + (request.path ?? "")) else { throw URLError(.badURL) }
        var urlRequest = URLRequest(url: url)
        urlRequest.httpMethod = request.method.rawValue
        for field in request.headerFields {
            urlRequest.addValue(field.value, forHTTPHeaderField: field.name.rawName)
        }
        if let body {
            urlRequest.httpBody = try await Data(collecting: body, upTo: 4_194_304)
        }
        let (data, response) = try await URLSession.shared.data(for: urlRequest)
        guard let http = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
        await log.add("\(request.method.rawValue) \(url.path) \(http.statusCode)")
        var fields = HTTPFields()
        for (name, value) in http.allHeaderFields {
            if let name = (name as? String).flatMap({ HTTPField.Name($0) }), let value = value as? String {
                fields.append(HTTPField(name: name, value: value))
            }
        }
        return (HTTPResponse(status: .init(code: http.statusCode), headerFields: fields), HTTPBody(data))
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
        let lines = String(decoding: data, as: UTF8.self).split(separator: "\n").map(String.init)
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
        guard let configPath = CommandLine.arguments.dropFirst().first,
              let data = FileManager.default.contents(atPath: configPath),
              let config = try? JSONDecoder().decode(ProbeConfig.self, from: data),
              let script = environment["PROBE_SIGN_IN_SCRIPT"]
        else {
            print("usage: PROBE_SIGN_IN_SCRIPT=<sign-in.cjs> probe <seeded config.json>")
            exit(3)
        }
        let probe = Probe(
            config: config,
            script: script,
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
    private let script: String
    private let configuration: AccountConfiguration
    private let machine = MachineDescription.current()
    private let scratch = "account-local-stack-\(UUID().uuidString)"
    private var directory: URL { FileManager.default.temporaryDirectory.appendingPathComponent(scratch, isDirectory: true) }

    init(config: ProbeConfig, script: String, configuration: AccountConfiguration) {
        self.config = config
        self.script = script
        self.configuration = configuration
    }

    func run() async {
        defer {
            try? FileManager.default.removeItem(at: directory)
            UserDefaults.standard.removePersistentDomain(forName: scratch)
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

        let devices = try? await services.devices.list()
        report.expect(
            devices?.contains { $0.machineId == machine.machineID && $0.licensedAt != nil } == true,
            "GET /v2/devices lists this Mac as licensed"
        )

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

        _ = await services.migrateLegacyKeyIfNeeded()

        guard case .deviceLimitReached(let holders) = services.access.state.refresh else {
            report.expect(false, "a fourth device gets device_limit_reached", "\(services.access.state.refresh)")
            return
        }
        report.expect(holders.count == 3, "device_limit_reached lists the 3 devices holding the slots", "\(holders.count)")
        report.expect(services.access.check(.iCloudSync) == .notIncluded, "past the device limit the app stays on Free")
    }

    // MARK: - Helpers

    private func services(log: CallLog, keychain: InMemoryKeychain, legacyKeychain: InMemoryKeychain) -> AccountServices {
        let entitlementFile = directory.appendingPathComponent(UUID().uuidString).appendingPathComponent("entitlement.jwt")
        let defaults = UserDefaults(suiteName: scratch) ?? .standard
        return AccountServices(
            configuration: configuration,
            machine: machine,
            transport: ProbeTransport(log: log),
            send: { request in
                let form = String(decoding: request.httpBody ?? Data(), as: UTF8.self)
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
