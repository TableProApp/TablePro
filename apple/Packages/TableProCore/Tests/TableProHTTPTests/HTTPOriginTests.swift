import Foundation
import TableProHTTP
import Testing

struct HTTPOriginTests {
    private static func origin(_ text: String) -> HTTPOrigin? {
        URL(string: text).flatMap(HTTPOrigin.init)
    }

    @Test("Scheme and host case and an explicit default port do not change the origin", arguments: [
        ("https://Example.COM/a", "https://example.com:443/b"),
        ("http://example.com", "HTTP://example.com:80/"),
        ("http://[::1]:8080/a", "http://[::1]:8080/b"),
    ])
    func sameOrigin(first: String, second: String) throws {
        let one = try #require(Self.origin(first))
        let other = try #require(Self.origin(second))
        #expect(one == other)
    }

    @Test("Scheme, host or port tells two origins apart", arguments: [
        ("https://example.com", "http://example.com"),
        ("https://example.com", "https://example.com:8443"),
        ("https://example.com", "https://www.example.com"),
        ("http://127.0.0.1:8200", "http://localhost:8200"),
    ])
    func differentOrigin(first: String, second: String) throws {
        let one = try #require(Self.origin(first))
        let other = try #require(Self.origin(second))
        #expect(one != other)
    }

    @Test("An IPv6 host loses its brackets and keeps its port")
    func ipv6() throws {
        let origin = try #require(Self.origin("http://[::1]:8250/oidc"))
        #expect(origin.host == "::1")
        #expect(origin.port == 8_250)
        #expect(origin.isLoopback)
        #expect(origin.url?.absoluteString == "http://[::1]:8250/")
    }

    @Test("A URL with user info, another scheme, no host or an encoded host has no origin", arguments: [
        "https://user@example.com/",
        "https://user:password@example.com/",
        "ftp://example.com/",
        "file:///etc/hosts",
        "https:///no-host",
        "/relative/path",
        "https://collector.example%2F.snowflakecomputing.com/",
    ])
    func noOrigin(text: String) {
        #expect(Self.origin(text) == nil)
    }
}
