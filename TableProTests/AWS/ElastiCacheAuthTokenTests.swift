import Foundation
import TableProPluginKit
import Testing

@Suite("ElastiCache IAM auth token")
struct ElastiCacheAuthTokenTests {
    private let credentials = AWSCredentials(
        accessKeyId: "AKIDEXAMPLE",
        secretAccessKey: "wJalrXUtnFEMI/K7MDENG+bPxRfiCYEXAMPLEKEY",
        sessionToken: nil
    )
    private let fixedDate = Date(timeIntervalSince1970: 1_440_938_160)

    private func makeToken(sessionToken: String? = nil) -> String {
        ElastiCacheAuthTokenGenerator.generateToken(
            replicationGroupId: "my-cache",
            region: "us-east-1",
            userId: "iam_user",
            credentials: AWSCredentials(
                accessKeyId: credentials.accessKeyId,
                secretAccessKey: credentials.secretAccessKey,
                sessionToken: sessionToken
            ),
            now: fixedDate
        )
    }

    @Test("Token has the documented shape and no scheme")
    func tokenShape() {
        let token = makeToken()
        #expect(!token.hasPrefix("https://"))
        #expect(token.hasPrefix("my-cache/?"))
        #expect(token.contains("Action=connect"))
        #expect(token.contains("User=iam_user"))
        #expect(token.contains("X-Amz-Algorithm=AWS4-HMAC-SHA256"))
        #expect(token.contains("X-Amz-Expires=900"))
        #expect(token.contains("X-Amz-Credential=AKIDEXAMPLE%2F"))
        #expect(token.contains("%2Felasticache%2Faws4_request"))
        #expect(token.contains("X-Amz-Signature="))
    }

    @Test("Same inputs produce the same token")
    func deterministic() {
        let first = makeToken()
        let second = makeToken()
        #expect(first == second)
    }

    @Test("Session token is included only for temporary credentials")
    func sessionToken() {
        #expect(!makeToken().contains("X-Amz-Security-Token"))
        #expect(makeToken(sessionToken: "FQoGZXIvYXdzEXAMPLE").contains("X-Amz-Security-Token=FQoGZXIvYXdzEXAMPLE"))
    }
}
