import Foundation
import TableProSnowflakeCore
import Testing

struct SnowflakeBrowserCallbackTests {
    private static func head(_ target: String, method: String = "GET") -> Data {
        Data("\(method) \(target) HTTP/1.1\r\nHost: localhost:49152\r\n\r\n".utf8)
    }

    @Test("The identity provider's redirect yields its SAML token")
    func redirectYieldsTheToken() {
        #expect(SnowflakeBrowserCallback.parse(requestHead: Self.head("/?token=ver%3A1-hint%3A2")) == .token("ver:1-hint:2"))
    }

    @Test("A request that is not the token redirect is ignored", arguments: [
        "/favicon.ico",
        "/",
        "/?token=",
        "/?token=a&token=b",
        "/?error=access_denied",
        "/other?token=abc"
    ])
    func strayRequestIsIgnored(target: String) {
        #expect(SnowflakeBrowserCallback.parse(requestHead: Self.head(target)) == .ignore)
    }

    @Test("Only a complete GET head in origin form is read")
    func otherRequestShapesAreIgnored() {
        #expect(SnowflakeBrowserCallback.parse(requestHead: Self.head("/?token=abc", method: "POST")) == .ignore)
        #expect(SnowflakeBrowserCallback.parse(requestHead: Data("GET /?token=abc HTTP/1.1\r\nHost: loc".utf8)) == .ignore)
        #expect(SnowflakeBrowserCallback.parse(requestHead: Data("GET http://localhost/?token=abc HTTP/1.1\r\n\r\n".utf8)) == .ignore)
        #expect(SnowflakeBrowserCallback.parse(requestHead: Data()) == .ignore)
    }
}
