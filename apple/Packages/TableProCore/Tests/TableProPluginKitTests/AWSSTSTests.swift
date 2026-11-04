import Foundation
import TableProPluginKit
import Testing

struct AWSSTSTests {
    private let validResponse = """
    <AssumeRoleResponse xmlns="https://sts.amazonaws.com/doc/2011-06-15/">
      <AssumeRoleResult>
        <AssumedRoleUser>
          <Arn>arn:aws:sts::123456789012:assumed-role/demo/tablepro</Arn>
          <AssumedRoleId>ARO123:tablepro</AssumedRoleId>
        </AssumedRoleUser>
        <Credentials>
          <AccessKeyId>ASIAEXAMPLE</AccessKeyId>
          <SecretAccessKey>secretexample</SecretAccessKey>
          <SessionToken>tokenexample</SessionToken>
          <Expiration>2026-06-03T12:00:00Z</Expiration>
        </Credentials>
      </AssumeRoleResult>
    </AssumeRoleResponse>
    """

    @Test("Parses credentials and expiration from a valid AssumeRole response")
    func parsesValidResponse() throws {
        let creds = try AWSSTS.parseAssumeRoleResponse(Data(validResponse.utf8), roleArn: "arn:aws:iam::123456789012:role/demo")
        #expect(creds.accessKeyId == "ASIAEXAMPLE")
        #expect(creds.secretAccessKey == "secretexample")
        #expect(creds.sessionToken == "tokenexample")
        let expected = ISO8601DateFormatter().date(from: "2026-06-03T12:00:00Z")
        #expect(creds.expiration == expected)
    }

    @Test("A redirect from STS is not followed, so the signed request and session token never reach the other host")
    func redirectIsNotFollowed() async {
        let credentials = validResponse
        let script = AWSSSOScriptedProtocol.Script { request, _ in
            request.url?.host == "collector.example"
                ? .json(credentials)
                : .init(status: 307, headers: ["Location": "https://collector.example/"])
        }
        let role = "arn:aws:iam::123456789012:role/demo"

        await #expect(throws: AWSAuthError.assumeRoleFailed(role: role, message: "HTTP 307")) {
            _ = try await AWSSTS.assumeRole(
                roleArn: role,
                roleSessionName: "tablepro",
                externalId: nil,
                durationSeconds: nil,
                region: "us-east-1",
                baseCredentials: AWSCredentials(accessKeyId: "AK", secretAccessKey: "SK", sessionToken: "BASE-TOKEN"),
                session: AWSSSOScriptedProtocol.session(for: script)
            )
        }
        let hosts = script.exchanges.map { $0.request.url?.host }
        #expect(hosts == ["sts.us-east-1.amazonaws.com"])
    }

    @Test("A response without credentials throws assumeRoleFailed")
    func throwsOnMissingCredentials() {
        let body = "<AssumeRoleResponse><AssumeRoleResult></AssumeRoleResult></AssumeRoleResponse>"
        #expect(throws: AWSAuthError.self) {
            _ = try AWSSTS.parseAssumeRoleResponse(Data(body.utf8), roleArn: "arn:aws:iam::1:role/x")
        }
    }
}
