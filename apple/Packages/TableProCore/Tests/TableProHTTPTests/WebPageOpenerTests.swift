import Foundation
import TableProHTTP
import Testing

struct WebPageOpenerTests {
    private static let scopes: [WebPageOpener.Scope] = [.https, .httpsOrLoopbackHTTP]

    @Test("An https sign-in page comes back as the server gave it", arguments: scopes)
    func keepsHTTPSPage(scope: WebPageOpener.Scope) {
        let page = "https://acme.okta.com/app/snowflake/sso/saml?SAMLRequest=abc%2Bdef&RelayState=49200"
        #expect(WebPageOpener.page(page, scope: scope)?.absoluteString == page)
        #expect(WebPageOpener.page("HTTPS://acme.okta.com/login", scope: scope)?.host == "acme.okta.com")
    }

    @Test("A value that is not an https web page never reaches Launch Services", arguments: [
        "file:///System/Applications/Calculator.app",
        "file:///Users/Shared/run.command",
        "smb://files.attacker.example/share",
        "vnc://attacker.example",
        "shortcuts://run-shortcut?name=Deploy",
        "tablepro://import?name=x&host=attacker.example&type=PostgreSQL",
        "http://idp.example/login",
        "javascript:alert(1)",
        "https:///no-host",
        "/System/Applications/Calculator.app",
        "",
        "https://user@idp.example/login",
    ], scopes)
    func refusesOtherValues(value: String, scope: WebPageOpener.Scope) {
        #expect(WebPageOpener.page(value, scope: scope) == nil)
    }

    @Test("Plain http to this Mac is a page only for the loopback scope", arguments: [
        "http://127.0.0.1:8080/auth",
        "http://localhost:8250/oidc/callback",
        "http://[::1]:8250/auth",
    ])
    func loopbackHTTP(value: String) {
        #expect(WebPageOpener.page(value, scope: .https) == nil)
        #expect(WebPageOpener.page(value, scope: .httpsOrLoopbackHTTP)?.absoluteString == value)
    }

    @Test("Opening a refused URL opens nothing")
    @MainActor
    func openRefuses() throws {
        let calculator = try #require(URL(string: "file:///System/Applications/Calculator.app"))
        let idp = try #require(URL(string: "http://idp.example/login"))
        #expect(WebPageOpener.open(calculator, scope: .httpsOrLoopbackHTTP) == false)
        #expect(WebPageOpener.open(idp, scope: .https) == false)
    }
}
