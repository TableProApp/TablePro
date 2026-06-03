import Foundation
import TableProPluginKit
import Testing

@Suite("AWS STS AssumeRole response parsing")
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

    @Test("A response without credentials throws assumeRoleFailed")
    func throwsOnMissingCredentials() {
        let body = "<AssumeRoleResponse><AssumeRoleResult></AssumeRoleResult></AssumeRoleResponse>"
        #expect(throws: AWSAuthError.self) {
            _ = try AWSSTS.parseAssumeRoleResponse(Data(body.utf8), roleArn: "arn:aws:iam::1:role/x")
        }
    }
}
