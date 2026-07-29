import Foundation
import TableProPluginKit
import Testing

@Suite("AWS SSO device login")
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
}
