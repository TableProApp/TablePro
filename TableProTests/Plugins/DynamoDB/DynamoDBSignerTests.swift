import Foundation
import TableProPluginKit
import Testing

@Suite("DynamoDB request signing")
struct DynamoDBSignerTests {
    private static let exampleDate = Date(timeIntervalSince1970: 1_440_938_160)
    private static let exampleCredentials = AWSCredentials(
        accessKeyId: "AKIDEXAMPLE",
        secretAccessKey: "wJalrXUtnFEMI/K7MDENG+bPxRfiCYEXAMPLEKEY",
        sessionToken: nil
    )
    private static let exampleToken =
        "AQoDYXdzEPT//////////wEXAMPLEtc764bNrC9SAPBSM22wDOk4x4HIZ8j4FZTwdQWLWsKWHGBuFqwAeMicRXmxfpSPfIeoIYRqTflfKD8YUuwthAx7mSEI/qkPpKPi/kMcGd"

    struct HostCase: Sendable, CustomTestStringConvertible {
        let url: String
        let expected: String
        var testDescription: String { url }
    }

    struct PathCase: Sendable, CustomTestStringConvertible {
        let url: String
        let expected: String
        var testDescription: String { url }
    }

    private static func listTablesRequest(_ urlText: String) throws -> URLRequest {
        var request = URLRequest(url: try #require(URL(string: urlText)))
        request.httpMethod = "POST"
        request.setValue("application/x-amz-json-1.0", forHTTPHeaderField: "Content-Type")
        request.setValue("DynamoDB_20120810.ListTables", forHTTPHeaderField: "X-Amz-Target")
        return request
    }

    @Test("Timestamps are formatted in UTC whatever the local time zone")
    func timestampsAreUTC() {
        let stamps = DynamoDBSigner.timestamps(for: Date(timeIntervalSince1970: 1_709_251_199))
        #expect(stamps == DynamoDBSigner.Timestamps(amzDate: "20240229T235959Z", dateStamp: "20240229"))
    }

    @Test("Timestamps pad every field to its fixed width")
    func timestampsArePadded() {
        #expect(DynamoDBSigner.timestamps(for: Date(timeIntervalSince1970: 1_767_582_245)).amzDate == "20260105T030405Z")
        #expect(DynamoDBSigner.timestamps(for: Date(timeIntervalSince1970: 0)).amzDate == "19700101T000000Z")
        #expect(DynamoDBSigner.timestamps(for: Self.exampleDate).dateStamp == "20150830")
    }

    @Test(
        "The Host header drops only the scheme's default port",
        arguments: [
            HostCase(url: "https://dynamodb.us-east-1.amazonaws.com:443/", expected: "dynamodb.us-east-1.amazonaws.com"),
            HostCase(url: "https://dynamodb.us-east-1.amazonaws.com/", expected: "dynamodb.us-east-1.amazonaws.com"),
            HostCase(url: "http://localhost:80/", expected: "localhost"),
            HostCase(url: "http://localhost:8000", expected: "localhost:8000"),
            HostCase(url: "https://ddb.example.com:8443/", expected: "ddb.example.com:8443"),
            HostCase(url: "http://ddb.example.com:443/", expected: "ddb.example.com:443"),
            HostCase(url: "https://ddb.example.com:80/", expected: "ddb.example.com:80")
        ]
    )
    func hostHeader(_ testCase: HostCase) throws {
        let url = try #require(URL(string: testCase.url))
        #expect(DynamoDBSigner.hostHeader(for: url) == testCase.expected)
    }

    @Test(
        "The Host header keeps the brackets around an IPv6 literal",
        arguments: [
            HostCase(url: "http://[::1]:8000", expected: "[::1]:8000"),
            HostCase(url: "https://[2001:db8::1]/", expected: "[2001:db8::1]")
        ]
    )
    func hostHeaderForIPv6(_ testCase: HostCase) throws {
        let url = try #require(URL(string: testCase.url))
        #expect(DynamoDBSigner.hostHeader(for: url) == testCase.expected)
    }

    @Test(
        "The canonical URI is the path as sent",
        arguments: [
            PathCase(url: "https://h/dynamodb/", expected: "/dynamodb/"),
            PathCase(url: "https://h/a%20b/c", expected: "/a%20b/c"),
            PathCase(url: "https://h/", expected: "/"),
            PathCase(url: "https://h", expected: "/"),
            PathCase(url: "http://localhost:8000", expected: "/")
        ]
    )
    func canonicalURI(_ testCase: PathCase) throws {
        let url = try #require(URL(string: testCase.url))
        #expect(DynamoDBSigner.canonicalURI(for: url) == testCase.expected)
    }

    @Test("Signing sets the date, the host and an Authorization header with the credential scope")
    func signSetsHeaders() throws {
        var request = try Self.listTablesRequest("https://dynamodb.us-east-1.amazonaws.com/")
        DynamoDBSigner.sign(
            &request, body: Data("{}".utf8), credentials: Self.exampleCredentials,
            region: "us-east-1", date: Self.exampleDate
        )
        #expect(request.value(forHTTPHeaderField: "X-Amz-Date") == "20150830T123600Z")
        #expect(request.value(forHTTPHeaderField: "Host") == "dynamodb.us-east-1.amazonaws.com")
        #expect(request.value(forHTTPHeaderField: "X-Amz-Security-Token") == nil)
        let authorization = try #require(request.value(forHTTPHeaderField: "Authorization"))
        #expect(authorization.hasPrefix(
            "AWS4-HMAC-SHA256 Credential=AKIDEXAMPLE/20150830/us-east-1/dynamodb/aws4_request, "
        ))
        #expect(authorization.contains("SignedHeaders=content-type;host;x-amz-date;x-amz-target, "))
    }

    @Test("The signature matches an independent SigV4 computation")
    func signatureMatchesReference() throws {
        var request = try Self.listTablesRequest("https://dynamodb.us-east-1.amazonaws.com/")
        DynamoDBSigner.sign(
            &request, body: Data("{}".utf8), credentials: Self.exampleCredentials,
            region: "us-east-1", date: Self.exampleDate
        )
        #expect(
            request.value(forHTTPHeaderField: "Authorization")
                == "AWS4-HMAC-SHA256 Credential=AKIDEXAMPLE/20150830/us-east-1/dynamodb/aws4_request, "
                + "SignedHeaders=content-type;host;x-amz-date;x-amz-target, "
                + "Signature=75214f17608dbd636679e18f6f89744844ae96fcd228b8147167152488d817de"
        )
    }

    @Test("A session token is sent and signed")
    func sessionTokenIsSigned() throws {
        var request = try Self.listTablesRequest("https://dynamodb.us-east-1.amazonaws.com/")
        let credentials = AWSCredentials(
            accessKeyId: "AKIDEXAMPLE",
            secretAccessKey: "wJalrXUtnFEMI/K7MDENG+bPxRfiCYEXAMPLEKEY",
            sessionToken: Self.exampleToken
        )
        DynamoDBSigner.sign(
            &request, body: Data("{}".utf8), credentials: credentials, region: "us-east-1", date: Self.exampleDate
        )
        #expect(request.value(forHTTPHeaderField: "X-Amz-Security-Token") == Self.exampleToken)
        #expect(
            request.value(forHTTPHeaderField: "Authorization")
                == "AWS4-HMAC-SHA256 Credential=AKIDEXAMPLE/20150830/us-east-1/dynamodb/aws4_request, "
                + "SignedHeaders=content-type;host;x-amz-date;x-amz-security-token;x-amz-target, "
                + "Signature=6fa03fc9356b96e0d654a933310ae874b0752797246b39df2a03cc67d4302dcd"
        )
    }

    @Test("An empty session token is neither sent nor signed")
    func emptySessionTokenIsIgnored() throws {
        var request = try Self.listTablesRequest("https://dynamodb.us-east-1.amazonaws.com/")
        let credentials = AWSCredentials(
            accessKeyId: "AKIDEXAMPLE",
            secretAccessKey: "wJalrXUtnFEMI/K7MDENG+bPxRfiCYEXAMPLEKEY",
            sessionToken: ""
        )
        DynamoDBSigner.sign(
            &request, body: Data("{}".utf8), credentials: credentials, region: "us-east-1", date: Self.exampleDate
        )
        #expect(request.value(forHTTPHeaderField: "X-Amz-Security-Token") == nil)
        let authorization = try #require(request.value(forHTTPHeaderField: "Authorization"))
        #expect(authorization.hasSuffix(
            "Signature=75214f17608dbd636679e18f6f89744844ae96fcd228b8147167152488d817de"
        ))
    }

    @Test("A custom endpoint signs its port and its percent-encoded path")
    func customEndpointSignature() throws {
        var request = try Self.listTablesRequest("http://localhost:8000/a%20b/c")
        DynamoDBSigner.sign(
            &request, body: Data("{}".utf8), credentials: Self.exampleCredentials,
            region: "us-east-1", date: Self.exampleDate
        )
        #expect(request.value(forHTTPHeaderField: "Host") == "localhost:8000")
        let authorization = try #require(request.value(forHTTPHeaderField: "Authorization"))
        #expect(authorization.hasSuffix(
            "Signature=54093f8b1a85d2095f252df1192f952b4d2b2205be51b10a3f313d0940dd0f52"
        ))
    }

    @Test("The signing region and date change the credential scope")
    func scopeFollowsRegionAndDate() throws {
        var request = try Self.listTablesRequest("https://dynamodb.cn-north-1.amazonaws.com.cn/")
        DynamoDBSigner.sign(
            &request, body: Data("{}".utf8), credentials: Self.exampleCredentials,
            region: "cn-north-1", date: Date(timeIntervalSince1970: 1_709_251_199)
        )
        let authorization = try #require(request.value(forHTTPHeaderField: "Authorization"))
        #expect(authorization.hasPrefix(
            "AWS4-HMAC-SHA256 Credential=AKIDEXAMPLE/20240229/cn-north-1/dynamodb/aws4_request, "
        ))
    }
}
