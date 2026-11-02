//
//  SameOriginRedirectGuardTests.swift
//  TableProTests
//

import Foundation
@testable import TablePro
import Testing

struct SameOriginRedirectGuardTests {
    private static func allows(_ origin: String, _ target: String) throws -> Bool {
        SameOriginRedirectGuard(origin: try #require(URL(string: origin))).allows(try #require(URL(string: target)))
    }

    @Test("A redirect on the same scheme, host and port is followed, the default port written or not")
    func sameOrigin() throws {
        #expect(try Self.allows("https://registry.example.com/base", "https://REGISTRY.example.com/other"))
        #expect(try Self.allows("http://registry.example.com", "http://registry.example.com:80/schemas"))
        #expect(try Self.allows("https://registry.example.com:443/", "https://registry.example.com/schemas"))
        #expect(try Self.allows("http://localhost:8081", "http://localhost:8081/subjects"))
    }

    @Test("A redirect to another host, port or scheme is refused, a downgrade to http included")
    func otherOrigin() throws {
        #expect(try !Self.allows("https://registry.example.com", "https://evil.example.com"))
        #expect(try !Self.allows("https://registry.example.com", "http://registry.example.com"))
        #expect(try !Self.allows("http://localhost:8081", "http://localhost:8082"))
        #expect(try !Self.allows("https://registry.example.com", "https://registry.example.com:8443"))
        #expect(try !Self.allows("https://registry.example.com", "file:///etc/passwd"))
    }
}
