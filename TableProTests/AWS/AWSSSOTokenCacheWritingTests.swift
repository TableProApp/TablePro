import Foundation
import TableProPluginKit
import Testing

@Suite("AWS SSO token cache writing")
struct AWSSSOTokenCacheWritingTests {
    private func makeCacheDirectory() throws -> String {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("tablepro-sso-cache-\(UUID().uuidString)")
            .appendingPathComponent("cache")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: directory.path)
        return directory.path
    }

    private func mode(_ path: String) throws -> Int {
        let attributes = try FileManager.default.attributesOfItem(atPath: path)
        return (attributes[.posixPermissions] as? NSNumber)?.intValue ?? 0
    }

    private func cacheFilePath(directory: String, cacheKey: String) -> String {
        let name = AWSSSO.sha1Hex(Data(cacheKey.utf8)) + ".json"
        return (directory as NSString).appendingPathComponent(name)
    }

    @Test("The token file is written 0600 inside a 0700 directory")
    func permissions() throws {
        let directory = try makeCacheDirectory()
        defer { try? FileManager.default.removeItem(atPath: directory) }

        try AWSSSOLogin.writeTokenCache(
            cacheKey: "corp",
            entry: AWSSSOTokenCacheEntry(
                accessToken: "AT",
                expiresAt: Date(timeIntervalSince1970: 1_780_488_000),
                region: "us-east-1",
                startUrl: "https://example.awsapps.com/start"
            ),
            cacheDirectory: directory
        )

        let path = cacheFilePath(directory: directory, cacheKey: "corp")
        #expect(try mode(path) == 0o600)
        #expect(try mode(directory) == 0o700)
    }

    @Test("An existing world-readable token file is tightened on the next write")
    func tightensExistingFile() throws {
        let directory = try makeCacheDirectory()
        defer { try? FileManager.default.removeItem(atPath: directory) }

        let path = cacheFilePath(directory: directory, cacheKey: "corp")
        FileManager.default.createFile(atPath: path, contents: Data("{}".utf8), attributes: [.posixPermissions: 0o644])
        #expect(try mode(path) == 0o644)

        try AWSSSOLogin.writeTokenCache(
            cacheKey: "corp",
            entry: AWSSSOTokenCacheEntry(
                accessToken: "AT",
                expiresAt: Date(timeIntervalSince1970: 1_780_488_000),
                region: "us-east-1",
                startUrl: "https://example.awsapps.com/start"
            ),
            cacheDirectory: directory
        )

        #expect(try mode(path) == 0o600)
    }

    @Test("The payload carries the refresh material the AWS CLI needs")
    func cliCompatiblePayload() throws {
        let data = try AWSSSOLogin.tokenCacheContents(
            entry: AWSSSOTokenCacheEntry(
                accessToken: "AT",
                expiresAt: Date(timeIntervalSince1970: 1_780_488_000),
                region: "us-east-1",
                startUrl: "https://example.awsapps.com/start",
                refreshToken: "RT",
                clientId: "CID",
                clientSecret: "CSECRET",
                registrationExpiresAt: Date(timeIntervalSince1970: 1_783_080_000)
            )
        )
        let payload = try #require(try JSONSerialization.jsonObject(with: data) as? [String: String])

        #expect(payload["accessToken"] == "AT")
        #expect(payload["expiresAt"] == "2026-06-03T12:00:00Z")
        #expect(payload["region"] == "us-east-1")
        #expect(payload["startUrl"] == "https://example.awsapps.com/start")
        #expect(payload["refreshToken"] == "RT")
        #expect(payload["clientId"] == "CID")
        #expect(payload["clientSecret"] == "CSECRET")
        #expect(payload["registrationExpiresAt"] == "2026-07-03T12:00:00Z")
    }

    @Test("A cache entry with no refresh material writes only the four base keys")
    func minimalPayload() throws {
        let data = try AWSSSOLogin.tokenCacheContents(
            accessToken: "AT",
            expiresAt: Date(timeIntervalSince1970: 1_780_488_000),
            region: "us-east-1",
            startUrl: "https://example.awsapps.com/start"
        )
        let payload = try #require(try JSONSerialization.jsonObject(with: data) as? [String: String])
        #expect(Set(payload.keys) == ["accessToken", "expiresAt", "region", "startUrl"])
    }

    @Test("Credentials never print their secret")
    func redactedDescription() {
        let credentials = AWSCredentials(
            accessKeyId: "AKIAIOSFODNN7EXAMPLE",
            secretAccessKey: "wJalrXUtnFEMI",
            sessionToken: "SESSION"
        )
        let printed = "\(credentials)"
        #expect(printed == "AWSCredentials(accessKeyId: AKIA…, redacted)")
        #expect(!printed.contains("wJalrXUtnFEMI"))
        #expect(!printed.contains("SESSION"))
    }
}
