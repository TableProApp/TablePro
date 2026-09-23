import Foundation
import TableProPluginKit
import Testing

@Suite("DynamoDB endpoint resolution")
struct DynamoDBEndpointTests {
    struct RegionCase: Sendable, CustomTestStringConvertible {
        let region: String
        let url: String
        var testDescription: String { region }
    }

    struct LoopbackCase: Sendable, CustomTestStringConvertible {
        let host: String
        let isLoopback: Bool
        var testDescription: String { host }
    }

    private static func noProfileRegion(_ name: String) -> String? {
        nil
    }

    private static var plainHTTPRefusal: DynamoDBError {
        .configuration(String(
            localized: "Plain HTTP is only allowed for an endpoint on this Mac (localhost). Use https:// for any other host."
        ))
    }

    private static func configurationMessage(of error: (any Error)?) -> String? {
        guard case .configuration(let message)? = error as? DynamoDBError else { return nil }
        return message
    }

    @Test(
        "The AWS host follows the region's partition",
        arguments: [
            RegionCase(region: "us-east-1", url: "https://dynamodb.us-east-1.amazonaws.com/"),
            RegionCase(region: "cn-north-1", url: "https://dynamodb.cn-north-1.amazonaws.com.cn/"),
            RegionCase(region: "us-gov-west-1", url: "https://dynamodb.us-gov-west-1.amazonaws.com/"),
            RegionCase(region: "eusc-de-east-1", url: "https://dynamodb.eusc-de-east-1.amazonaws.eu/")
        ]
    )
    func partitionHost(_ testCase: RegionCase) throws {
        let endpoint = try DynamoDBEndpoint.resolve(
            fields: ["awsAuthMethod": "credentials", "awsRegion": testCase.region],
            profileRegion: Self.noProfileRegion
        )
        #expect(endpoint.url.absoluteString == testCase.url)
        #expect(endpoint.signingRegion == testCase.region)
        #expect(!endpoint.isLocal)
    }

    @Test(
        "A region that is not a region name is refused before it becomes part of a host",
        arguments: ["evil.example#", "us-east-1/../x", "user@evil.example", "us east 1", "-us-east-1", "us-east-1.", "a\r\nb"]
    )
    func malformedRegionIsRefused(_ region: String) {
        #expect(throws: DynamoDBError.self) {
            try DynamoDBEndpoint.resolve(fields: ["awsRegion": region], profileRegion: Self.noProfileRegion)
        }
    }

    @Test("A profile's malformed region is refused too")
    func malformedProfileRegionIsRefused() {
        #expect(throws: DynamoDBError.self) {
            try DynamoDBEndpoint.resolve(fields: ["awsAuthMethod": "profile"], profileRegion: { _ in "evil.example#" })
        }
    }

    @Test("A typed region is trimmed and lowercased")
    func typedRegionIsCanonical() throws {
        let endpoint = try DynamoDBEndpoint.resolve(
            fields: ["awsRegion": "  EU-West-2 \n"], profileRegion: Self.noProfileRegion
        )
        #expect(endpoint.signingRegion == "eu-west-2")
        #expect(endpoint.url.absoluteString == "https://dynamodb.eu-west-2.amazonaws.com/")
    }

    @Test("An empty region takes the profile's region for profile and SSO auth", arguments: ["profile", "sso"])
    func emptyRegionUsesProfileRegion(_ method: String) throws {
        let asked = EndpointProfileLookupLog()
        let endpoint = try DynamoDBEndpoint.resolve(
            fields: ["awsAuthMethod": method, "awsRegion": "", "awsProfileName": "work"],
            profileRegion: { name in
                asked.append(name)
                return name == "work" ? "ap-southeast-2" : nil
            }
        )
        #expect(endpoint.signingRegion == "ap-southeast-2")
        #expect(endpoint.url.absoluteString == "https://dynamodb.ap-southeast-2.amazonaws.com/")
        #expect(asked.names == ["work"])
    }

    @Test("An empty profile name reads the default profile's region")
    func emptyProfileNameReadsDefault() throws {
        let endpoint = try DynamoDBEndpoint.resolve(
            fields: ["awsAuthMethod": "profile", "awsProfileName": ""],
            profileRegion: { $0 == "default" ? "sa-east-1" : nil }
        )
        #expect(endpoint.signingRegion == "sa-east-1")
    }

    @Test("A profile with no region falls back to us-east-1")
    func profileWithoutRegionFallsBack() throws {
        let endpoint = try DynamoDBEndpoint.resolve(
            fields: ["awsAuthMethod": "profile", "awsProfileName": "work"], profileRegion: Self.noProfileRegion
        )
        #expect(endpoint.signingRegion == "us-east-1")
    }

    @Test("Access key auth with no region uses us-east-1 and never reads a profile")
    func accessKeyIgnoresProfileRegion() throws {
        let asked = EndpointProfileLookupLog()
        let endpoint = try DynamoDBEndpoint.resolve(
            fields: ["awsAuthMethod": "credentials", "awsProfileName": "work"],
            profileRegion: { name in
                asked.append(name)
                return "eu-central-1"
            }
        )
        #expect(endpoint.signingRegion == "us-east-1")
        #expect(asked.names.isEmpty)
    }

    @Test("The region field wins over the profile's region")
    func regionFieldWinsOverProfile() throws {
        let endpoint = try DynamoDBEndpoint.resolve(
            fields: ["awsAuthMethod": "profile", "awsProfileName": "work", "awsRegion": "ap-northeast-1"],
            profileRegion: { _ in "eu-west-1" }
        )
        #expect(endpoint.signingRegion == "ap-northeast-1")
        #expect(endpoint.url.absoluteString == "https://dynamodb.ap-northeast-1.amazonaws.com/")
    }

    @Test("A custom HTTPS endpoint is kept with its path and signs for the typed region")
    func customHTTPSEndpointKeepsPath() throws {
        let endpoint = try DynamoDBEndpoint.resolve(
            fields: ["awsRegion": "eu-west-1", "awsEndpointUrl": "  https://ddb.example.com/prefix/  "],
            profileRegion: Self.noProfileRegion
        )
        #expect(endpoint.url.absoluteString == "https://ddb.example.com/prefix/")
        #expect(endpoint.url.path(percentEncoded: true) == "/prefix/")
        #expect(endpoint.signingRegion == "eu-west-1")
        #expect(!endpoint.isLocal)
    }

    @Test(
        "Plain HTTP to this Mac is allowed and marked local",
        arguments: ["http://localhost:8000", "http://127.0.0.1:8000", "http://[::1]:8000"]
    )
    func loopbackHTTPIsAllowed(_ text: String) throws {
        let endpoint = try DynamoDBEndpoint.resolve(
            fields: ["awsAuthMethod": "credentials", "awsEndpointUrl": text], profileRegion: Self.noProfileRegion
        )
        #expect(endpoint.url.absoluteString == text)
        #expect(endpoint.isLocal)
        #expect(endpoint.signingRegion == "us-east-1")
    }

    @Test(
        "Plain HTTP to any other host is refused",
        arguments: ["http://192.168.1.5:8000", "http://localhost.evil.com", "http://127.0.0.1.nip.io:8000"]
    )
    func remoteHTTPIsRefused(_ text: String) {
        #expect(throws: Self.plainHTTPRefusal) {
            try DynamoDBEndpoint.resolve(
                fields: ["awsAuthMethod": "credentials", "awsEndpointUrl": text], profileRegion: Self.noProfileRegion
            )
        }
    }

    @Test("HTTPS to a remote host is allowed and not local")
    func remoteHTTPSIsAllowed() throws {
        let endpoint = try DynamoDBEndpoint.resolve(
            fields: ["awsEndpointUrl": "https://192.168.1.5:8000"], profileRegion: Self.noProfileRegion
        )
        #expect(!endpoint.isLocal)
    }

    @Test("Local auth with no endpoint reaches localhost:8000", arguments: ["", "   "])
    func localAuthDefaultsToLocalhost(_ endpointText: String) throws {
        let endpoint = try DynamoDBEndpoint.resolve(
            fields: ["awsAuthMethod": "local", "awsEndpointUrl": endpointText], profileRegion: Self.noProfileRegion
        )
        #expect(endpoint.url.absoluteString == "http://localhost:8000")
        #expect(endpoint.isLocal)
        #expect(endpoint.signingRegion == "us-east-1")
    }

    @Test("Local auth with no endpoint field at all reaches localhost:8000")
    func localAuthWithoutField() throws {
        let endpoint = try DynamoDBEndpoint.resolve(fields: ["awsAuthMethod": "local"], profileRegion: Self.noProfileRegion)
        #expect(endpoint.url.absoluteString == DynamoDBEndpoint.localDefaultURL)
        #expect(endpoint.isLocal)
    }

    @Test("A malformed endpoint is a configuration error", arguments: ["not a url", "localhost:8000", "https://"])
    func malformedEndpointIsRejected(_ text: String) {
        let error = #expect(throws: DynamoDBError.self) {
            try DynamoDBEndpoint.resolve(fields: ["awsEndpointUrl": text], profileRegion: Self.noProfileRegion)
        }
        #expect(Self.configurationMessage(of: error) != nil)
    }

    @Test("An endpoint with another scheme is a configuration error")
    func otherSchemeIsRejected() {
        #expect(throws: DynamoDBError.configuration(String(localized: "The endpoint must start with https:// or http://"))) {
            try DynamoDBEndpoint.resolve(fields: ["awsEndpointUrl": "ftp://localhost:8000"], profileRegion: Self.noProfileRegion)
        }
    }

    @Test(
        "Loopback is decided from the literal host",
        arguments: [
            LoopbackCase(host: "localhost", isLoopback: true),
            LoopbackCase(host: "LocalHost", isLoopback: true),
            LoopbackCase(host: "127.0.0.1", isLoopback: true),
            LoopbackCase(host: "127.1.2.3", isLoopback: true),
            LoopbackCase(host: "::1", isLoopback: true),
            LoopbackCase(host: "[::1]", isLoopback: true),
            LoopbackCase(host: "127.0.0.1.nip.io", isLoopback: false),
            LoopbackCase(host: "localhost.evil.com", isLoopback: false),
            LoopbackCase(host: "128.0.0.1", isLoopback: false),
            LoopbackCase(host: "127.0.0", isLoopback: false),
            LoopbackCase(host: "127.256.0.1", isLoopback: false),
            LoopbackCase(host: "0.0.0.0", isLoopback: false),
            LoopbackCase(host: "", isLoopback: false)
        ]
    )
    func loopbackHost(_ testCase: LoopbackCase) {
        #expect(DynamoDBEndpoint.isLoopbackHost(testCase.host) == testCase.isLoopback)
    }
}

private final class EndpointProfileLookupLog: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [String] = []

    func append(_ name: String) {
        lock.withLock { stored.append(name) }
    }

    var names: [String] {
        lock.withLock { stored }
    }
}
