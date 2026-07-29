import Foundation
import TableProPluginKit
import Testing

@Suite("AWS Keyspaces SigV4 authentication")
struct KeyspacesSigV4Tests {
    private let credentials = AWSCredentials(
        accessKeyId: "AKIDEXAMPLE",
        secretAccessKey: "wJalrXUtnFEMI/K7MDENG+bPxRfiCYEXAMPLEKEY",
        sessionToken: nil
    )
    private let fixedDate = Date(timeIntervalSince1970: 1_440_938_160)

    @Test("The initial SASL response is SigV4 followed by two null bytes")
    func initialResponse() {
        #expect(Array(KeyspacesSigV4.initialResponse.utf8) == [0x53, 0x69, 0x67, 0x56, 0x34, 0x00, 0x00])
    }

    @Test("Extracts the 32-byte nonce that follows the nonce= marker")
    func nonceExtraction() {
        let nonceBytes = Data((0..<32).map { UInt8($0) })
        var challenge = Data("nonce=".utf8)
        challenge.append(nonceBytes)
        challenge.append(Data(",foo=bar".utf8))
        #expect(KeyspacesSigV4.nonce(fromChallenge: challenge) == nonceBytes)
    }

    @Test("Returns nil when the challenge has no nonce")
    func nonceMissing() {
        #expect(KeyspacesSigV4.nonce(fromChallenge: Data("hello".utf8)) == nil)
    }

    @Test("Returns nil when the nonce is shorter than 32 bytes")
    func nonceTruncated() {
        let challenge = Data("nonce=".utf8) + Data((0..<10).map { UInt8($0) })
        #expect(KeyspacesSigV4.nonce(fromChallenge: challenge) == nil)
    }

    @Test("The auth response carries signature, access key, and amzdate")
    func authResponseShape() {
        let nonce = Data((0..<32).map { UInt8($0) })
        let response = KeyspacesSigV4.authResponse(
            nonce: nonce, credentials: credentials, region: "us-east-1", now: fixedDate
        )
        let fields = Dictionary(uniqueKeysWithValues: response.split(separator: ",").compactMap { pair -> (String, String)? in
            let parts = pair.split(separator: "=", maxSplits: 1)
            guard parts.count == 2 else { return nil }
            return (String(parts[0]), String(parts[1]))
        })
        #expect(fields["access_key"] == "AKIDEXAMPLE")
        #expect(fields["amzdate"] == "20150830T123600Z")
        #expect(fields["signature"]?.count == 64)
        #expect(fields["session_token"] == nil)
    }

    @Test("A session token is included for temporary credentials")
    func includesSessionToken() {
        let temporary = AWSCredentials(
            accessKeyId: "ASIA", secretAccessKey: "secret", sessionToken: "TEMP_TOKEN"
        )
        let response = KeyspacesSigV4.authResponse(
            nonce: Data(repeating: 7, count: 32), credentials: temporary, region: "eu-west-1", now: fixedDate
        )
        #expect(response.contains("session_token=TEMP_TOKEN"))
    }

    @Test("Same inputs produce the same signature")
    func deterministic() {
        let nonce = Data(repeating: 9, count: 32)
        let first = KeyspacesSigV4.authResponse(nonce: nonce, credentials: credentials, region: "us-east-1", now: fixedDate)
        let second = KeyspacesSigV4.authResponse(nonce: nonce, credentials: credentials, region: "us-east-1", now: fixedDate)
        #expect(first == second)
    }
}
