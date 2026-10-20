import Foundation
@testable import TableProPluginKit
import Testing

struct AWSSSOLoginTests {
    @Test("Parses a device authorization response, defaulting the poll interval")
    func parsesDeviceAuthorization() throws {
        let json = """
        {
          "deviceCode": "DC",
          "userCode": "ABCD-EFGH",
          "verificationUri": "https://device.sso.us-east-1.amazonaws.com/",
          "verificationUriComplete": "https://device.sso.us-east-1.amazonaws.com/?user_code=ABCD-EFGH",
          "expiresIn": 600
        }
        """
        let auth = try AWSSSOLogin.parseDeviceAuthorization(Data(json.utf8))
        #expect(auth.deviceCode == "DC")
        #expect(auth.userCode == "ABCD-EFGH")
        #expect(auth.verificationUriComplete.contains("user_code=ABCD-EFGH"))
        #expect(auth.expiresIn == 600)
        #expect(auth.interval == 5)
    }

    @Test("Token poll maps status and OIDC error codes to states")
    func interpretsTokenPoll() {
        let success = #"{"accessToken":"AT","expiresIn":3600,"tokenType":"Bearer"}"#
        #expect(AWSSSOLogin.interpretTokenResponse(status: 200, data: Data(success.utf8))
            == .token(accessToken: "AT", expiresIn: 3_600))

        func poll(_ code: String) -> AWSSSOLogin.TokenPoll {
            AWSSSOLogin.interpretTokenResponse(status: 400, data: Data(#"{"error":"\#(code)"}"#.utf8))
        }
        #expect(poll("authorization_pending") == .pending)
        #expect(poll("slow_down") == .slowDown)
        #expect(poll("access_denied") == .denied)
        #expect(poll("expired_token") == .expired)
        #expect(poll("invalid_grant") == .failed("invalid_grant"))
    }

    @Test("Token cache contents match the AWS CLI shape")
    func tokenCacheContents() throws {
        let expiresAt = try #require(ISO8601DateFormatter().date(from: "2026-06-03T12:00:00Z"))
        let data = try AWSSSOLogin.tokenCacheContents(
            accessToken: "AT",
            expiresAt: expiresAt,
            region: "us-east-1",
            startUrl: "https://example.awsapps.com/start"
        )
        let object = try JSONSerialization.jsonObject(with: data) as? [String: String]
        #expect(object?["accessToken"] == "AT")
        #expect(object?["expiresAt"] == "2026-06-03T12:00:00Z")
        #expect(object?["region"] == "us-east-1")
        #expect(object?["startUrl"] == "https://example.awsapps.com/start")
    }

    @Test("authorize registers, shows the code, polls past pending and slow_down, and returns the token")
    func authorizeReturnsToken() async throws {
        let script = deviceFlowScript(interval: 2, tokenReplies: [.pending, .slowDown, .issued])
        let clock = SteppingClock()
        let presented = PresentedCodes()
        let startedAt = Date()

        let entry = try await AWSSSOLogin.authorize(
            region: "eu-west-1",
            startUrl: "https://example.awsapps.com/start",
            presentCode: { url, userCode in presented.record(url: url, userCode: userCode) },
            session: AWSSSOScriptedProtocol.session(for: script),
            clock: clock
        )

        #expect(entry.accessToken == "AT")
        #expect(entry.refreshToken == "RT")
        #expect(entry.region == "eu-west-1")
        #expect(entry.startUrl == "https://example.awsapps.com/start")
        #expect(entry.clientId == "CID")
        #expect(entry.clientSecret == "CSECRET")
        #expect(entry.registrationExpiresAt == Date(timeIntervalSince1970: 1_893_456_000))
        let lifetime = entry.expiresAt.timeIntervalSince(startedAt)
        #expect(lifetime >= 28_800 && lifetime < 28_800 + 60)

        let verificationURL = try #require(URL(string: "https://device.sso.eu-west-1.amazonaws.com/?user_code=ABCD-EFGH"))
        #expect(presented.all == [PresentedCodes.Code(url: verificationURL, userCode: "ABCD-EFGH")])
        #expect(clock.sleeps == [.seconds(2), .seconds(2), .seconds(7)])

        #expect(script.exchanges.allSatisfy { $0.request.url?.host == "oidc.eu-west-1.amazonaws.com" })
        let device = try #require(script.calls(to: "/device_authorization").first)
        #expect(try jsonStrings(device.body) == [
            "clientId": "CID",
            "clientSecret": "CSECRET",
            "startUrl": "https://example.awsapps.com/start"
        ])
        let polls = script.calls(to: "/token")
        try #require(polls.count == 3)
        #expect(try jsonStrings(polls[0].body) == [
            "clientId": "CID",
            "clientSecret": "CSECRET",
            "grantType": "urn:ietf:params:oauth:grant-type:device_code",
            "deviceCode": "DC"
        ])
    }

    @Test("authorize throws accessDenied when the user denies the request")
    func authorizeDenied() async {
        let script = deviceFlowScript(tokenReplies: [.pending, .denied])
        await #expect(throws: AWSSSOLoginError.accessDenied) {
            _ = try await AWSSSOLogin.authorize(
                region: "us-east-1",
                startUrl: "https://example.awsapps.com/start",
                presentCode: { _, _ in },
                session: AWSSSOScriptedProtocol.session(for: script),
                clock: SteppingClock()
            )
        }
    }

    @Test("authorize stops polling when the device code expires")
    func authorizeTimesOut() async {
        let script = deviceFlowScript(interval: 1, expiresIn: 3, tokenReplies: [.pending])
        let clock = SteppingClock()
        await #expect(throws: AWSSSOLoginError.authorizationTimedOut) {
            _ = try await AWSSSOLogin.authorize(
                region: "us-east-1",
                startUrl: "https://example.awsapps.com/start",
                presentCode: { _, _ in },
                session: AWSSSOScriptedProtocol.session(for: script),
                clock: clock
            )
        }
        #expect(clock.sleeps == [.seconds(1), .seconds(1), .seconds(1)])
        #expect(script.calls(to: "/token").count == 3)
    }

    @Test("authorize reports why AWS refused the start URL, before showing any code")
    func authorizeReportsRefusedStartUrl() async {
        let refusal = AWSSSOScriptedProtocol.Reply.json(
            #"{"error":"invalid_request","error_description":"Invalid start url"}"#,
            status: 400
        )
        let script = deviceFlowScript(deviceAuthorization: refusal, tokenReplies: [.issued])
        let presented = PresentedCodes()
        await #expect(throws: AWSSSOLoginError.serverError("Invalid start url")) {
            _ = try await AWSSSOLogin.authorize(
                region: "us-east-1",
                startUrl: "https://typo.awsapps.com/start",
                presentCode: { url, userCode in presented.record(url: url, userCode: userCode) },
                session: AWSSSOScriptedProtocol.session(for: script),
                clock: SteppingClock()
            )
        }
        #expect(presented.all.isEmpty)
        #expect(script.calls(to: "/token").isEmpty)
    }

    @Test("login signs in through authorize and writes the CLI cache file for the sso-session")
    func loginWritesTokenCache() async throws {
        let config = """
        [sso-session work]
        sso_start_url = https://example.awsapps.com/start
        sso_region = eu-west-1

        [profile dev]
        sso_session = work
        sso_account_id = 111111111111
        sso_role_name = Developer
        """
        let cacheDirectory = NSTemporaryDirectory() + "AWSSSOLoginTests_\(UUID().uuidString)"
        defer { try? FileManager.default.removeItem(atPath: cacheDirectory) }
        let script = deviceFlowScript(tokenReplies: [.issued])
        let presented = PresentedCodes()

        try await AWSSSOLogin.login(
            profileName: "dev",
            configContents: config,
            cacheDirectory: cacheDirectory,
            openVerificationURL: { url in presented.record(url: url, userCode: "") },
            session: AWSSSOScriptedProtocol.session(for: script),
            clock: SteppingClock()
        )

        #expect(presented.all.map { $0.url.absoluteString } == [
            "https://device.sso.eu-west-1.amazonaws.com/?user_code=ABCD-EFGH"
        ])
        let path = (cacheDirectory as NSString).appendingPathComponent(AWSSSO.sha1Hex(Data("work".utf8)) + ".json")
        let data = try #require(FileManager.default.contents(atPath: path))
        let cache = try jsonStrings(data)
        #expect(cache["accessToken"] == "AT")
        #expect(cache["refreshToken"] == "RT")
        #expect(cache["region"] == "eu-west-1")
        #expect(cache["startUrl"] == "https://example.awsapps.com/start")
        #expect(cache["clientId"] == "CID")
        #expect(cache["clientSecret"] == "CSECRET")
    }
}

private extension AWSSSOScriptedProtocol.Reply {
    static let pending = json(#"{"error":"authorization_pending"}"#, status: 400)
    static let slowDown = json(#"{"error":"slow_down"}"#, status: 400)
    static let denied = json(#"{"error":"access_denied"}"#, status: 400)
    static let issued = json(#"{"accessToken":"AT","expiresIn":28800,"refreshToken":"RT","tokenType":"Bearer"}"#)
}

private func deviceFlowScript(
    interval: Int = 1,
    expiresIn: Int = 600,
    deviceAuthorization: AWSSSOScriptedProtocol.Reply? = nil,
    tokenReplies: [AWSSSOScriptedProtocol.Reply]
) -> AWSSSOScriptedProtocol.Script {
    let authorization = deviceAuthorization ?? AWSSSOScriptedProtocol.Reply.json(#"""
    {"deviceCode":"DC","userCode":"ABCD-EFGH",
     "verificationUri":"https://device.sso.eu-west-1.amazonaws.com/",
     "verificationUriComplete":"https://device.sso.eu-west-1.amazonaws.com/?user_code=ABCD-EFGH",
     "expiresIn":\#(expiresIn),"interval":\#(interval)}
    """#)
    return AWSSSOScriptedProtocol.Script { request, callIndex in
        switch request.url?.path {
        case "/client/register"?:
            return .json(#"{"clientId":"CID","clientSecret":"CSECRET","clientSecretExpiresAt":1893456000}"#)
        case "/device_authorization"?:
            return authorization
        case "/token"?:
            return tokenReplies[min(callIndex, tokenReplies.count - 1)]
        default:
            return .json(#"{"error":"not_found"}"#, status: 404)
        }
    }
}

private func jsonStrings(_ data: Data) throws -> [String: String] {
    try #require(JSONSerialization.jsonObject(with: data) as? [String: String])
}

private final class PresentedCodes: @unchecked Sendable {
    struct Code: Equatable {
        let url: URL
        let userCode: String
    }

    private let lock = NSLock()
    private var recorded: [Code] = []

    var all: [Code] {
        lock.withLock { recorded }
    }

    func record(url: URL, userCode: String) {
        lock.withLock { recorded.append(Code(url: url, userCode: userCode)) }
    }
}

// Each sleep returns at once and moves time to its deadline, so a poll loop runs without waiting.
private final class SteppingClock: Clock, @unchecked Sendable {
    struct Instant: InstantProtocol {
        let offset: Duration

        func advanced(by duration: Duration) -> Instant {
            Instant(offset: offset + duration)
        }

        func duration(to other: Instant) -> Duration {
            other.offset - offset
        }

        static func < (lhs: Instant, rhs: Instant) -> Bool {
            lhs.offset < rhs.offset
        }
    }

    private let lock = NSLock()
    private var current = Instant(offset: .zero)
    private var recorded: [Duration] = []

    var now: Instant {
        lock.withLock { current }
    }

    var minimumResolution: Duration {
        .zero
    }

    var sleeps: [Duration] {
        lock.withLock { recorded }
    }

    func sleep(until deadline: Instant, tolerance: Duration?) async throws {
        try Task.checkCancellation()
        lock.withLock {
            recorded.append(current.duration(to: deadline))
            current = max(current, deadline)
        }
    }
}
