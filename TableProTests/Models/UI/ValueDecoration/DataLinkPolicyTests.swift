//
//  DataLinkPolicyTests.swift
//  TableProTests
//

import Foundation
import Testing

@testable import TablePro

struct DataLinkPolicyTests {
    /// Spells out what a failure message could not show: an invisible character, a space, a tab.
    private static func visible(_ input: String) -> String {
        var output = ""
        for scalar in input.unicodeScalars {
            if ("\u{21}"..."\u{7E}").contains(scalar) {
                output.unicodeScalars.append(scalar)
            } else {
                output += String(format: "<U+%04X>", scalar.value)
            }
        }
        return output
    }

    private static func expectLinks(_ inputs: [String]) {
        for input in inputs {
            #expect(DataLinkPolicy.openableURL(from: input)?.absoluteString == input, "\(visible(input))")
        }
    }

    private static func expectNoLink(_ inputs: [String]) {
        for input in inputs {
            #expect(DataLinkPolicy.openableURL(from: input) == nil, "\(visible(input))")
        }
    }

    // MARK: - Allowed

    @Test("A whole http, https or mailto value is a link, and the URL is the value as written")
    func allowedValues() {
        Self.expectLinks([
            "https://example.com/a?b=c#d",
            "http://localhost:8080/x",
            "mailto:someone@example.com",
            "https://example.com",
            "http://localhost",
            "https://a/",
            "https://example.com#",
            "https://example.com?",
            "https://example.com/?a=b&c=d#frag/x?y",
            "https://example.com/~user/_x-y.z",
            "https://example.com/a;b=c,d!e$f&g'h(i)j*k+l",
            "https://example.com/@handle",
            "http://127.0.0.1:5432/",
            "http://[::1]:8080/x"
        ])
    }

    @Test("The scheme matches in any case and the URL keeps the case it was written in")
    func schemeIsCaseInsensitive() {
        Self.expectLinks(["HTTPS://EXAMPLE.COM", "Http://Example.com/Path", "MAILTO:A@B.COM", "https://EXAMPLE.com/Path"])
    }

    /// A percent escape is text the row shows as it is, so it passes: the browser gets the same
    /// characters the user reads.
    @Test("Percent escapes pass unchanged, including an escaped control or bidi character")
    func percentEscapesPass() {
        Self.expectLinks([
            "https://example.com/path%20with%20escapes",
            "https://example.com/%00%0d%0aSet-Cookie:x",
            "https://example.com/%E2%80%AEgnp.exe"
        ])
    }

    @Test("A Punycode host passes, because the row shows the Punycode")
    func punycodeHostPasses() {
        Self.expectLinks(["https://xn--pple-43d.com/login"])
    }

    // MARK: - Schemes

    @Test("A value with no scheme, or with text around the URL, is not a link")
    func bareHostsAndProseAreNotLinks() {
        Self.expectNoLink([
            "", "example.com", "www.example.com", "//example.com/x", "see https://example.com for more",
            "https://example.com for more", "URL: https://example.com", "<https://example.com>", "https", "http://"
        ])
    }

    @Test("A scheme that reaches the file system, this app or another app is not a link")
    func otherSchemesAreNotLinks() {
        Self.expectNoLink([
            "file:///etc/passwd",
            "file:///System/Applications/Calculator.app",
            "tablepro://connect?host=evil",
            "postgres://user:pw@host/db",
            "postgresql://host/db",
            "mysql://root@localhost/db",
            "redis://localhost:6379",
            "mongodb+srv://cluster.example.com/db",
            "javascript:alert(1)",
            "data:text/html,<b>x</b>",
            "smb://server/share",
            "ssh://host",
            "vnc://host",
            "ftp://example.com/file",
            "tel:+15551234567",
            "x-apple.systempreferences:com.apple.preference.security",
            "httpx://example.com",
            "xhttps://example.com"
        ])
    }

    // MARK: - Host and user info

    @Test("http and https need the two slashes and a host")
    func missingHostIsNotALink() {
        Self.expectNoLink([
            "https://", "https:///path", "https:////evil.example/", "https://:8080/", "https://?q=1", "https://#top",
            "https:example.com", "https:/example.com", "http:example.com", "http:/example.com"
        ])
    }

    @Test("User info is refused, so a trusted name before the @ cannot hide the real host")
    func userInfoIsNotALink() {
        Self.expectNoLink([
            "https://apple.com@evil.example/login",
            "https://user@example.com/",
            "https://user:pw@example.com/",
            "https://:@example.com/",
            "https://@example.com/",
            "https://a@b@c/",
            "https://example.com\\@evil.example/",
            "https://evil.example\\.example.com/"
        ])
    }

    // MARK: - Characters

    /// The row would read as `apple.com` while the browser opened `xn--pple-43d.com`.
    @Test("A host or path outside ASCII is not a link, which rules out an IDN homograph")
    func nonASCIIIsNotALink() {
        Self.expectNoLink([
            "https://\u{0430}pple.com/login",
            "https://m\u{00FC}nchen.de/stra\u{00DF}e",
            "https://vi.wikipedia.org/wiki/Vi\u{1EC7}t_Nam",
            "https://example.com/caf\u{00E9}",
            "https://example.com/?q=\u{65E5}\u{672C}",
            "\u{FF48}ttps://example.com",
            "mailto:jos\u{00E9}@example.com",
            "mailto:someone@ex\u{0430}mple.com"
        ])
    }

    @Test("An invisible or bidi character anywhere in the value refuses it")
    func invisibleCharactersAreNotLinks() {
        let scalars: [Unicode.Scalar] = [
            "\u{061C}", "\u{200B}", "\u{200C}", "\u{200D}", "\u{200E}", "\u{200F}",
            "\u{202A}", "\u{202B}", "\u{202C}", "\u{202D}", "\u{202E}",
            "\u{2060}", "\u{2066}", "\u{2067}", "\u{2068}", "\u{2069}",
            "\u{FEFF}", "\u{00AD}", "\u{00A0}", "\u{3000}", "\u{2028}", "\u{0085}"
        ]
        func rows(_ inserted: String) -> [String] {
            [
                "https://exa\(inserted)mple.com/",
                "https://example.com/\(inserted)x",
                "https://example.com/gnp.exe\(inserted)",
                "mailto:some\(inserted)one@example.com"
            ]
        }
        /// The same rows with a letter in that place are links, so only the character refuses them.
        Self.expectLinks(rows("x"))
        for scalar in scalars {
            let inserted = String(scalar)
            Self.expectNoLink(rows(inserted) + ["\(inserted)https://example.com/", "ht\(inserted)tps://example.com/"])
        }
    }

    @Test("Whitespace and control characters refuse the value, and nothing is trimmed")
    func whitespaceIsNotTrimmed() {
        Self.expectNoLink([
            "\thttps://example.com",
            " https://example.com",
            "https://example.com ",
            " https://example.com ",
            "https://example.com\t",
            "https://example.com\n",
            "https://example.com\r\n",
            "\nhttps://example.com",
            "https://exa mple.com/a b",
            "https://example.com/a b",
            "https://example.com/a\tb",
            "https://example.com/\u{0}",
            "https://example.com/\u{7F}",
            "http\u{1A}//example.com",
            "mailto:a b@c.com",
            "mailto:a@b.com ",
            " mailto:a@b.com"
        ])
    }

    /// From macOS 14 `URLComponents` escapes most of these instead of failing, and the link would
    /// open a URL the row does not show.
    @Test("A character or escape a URL cannot hold is not a link")
    func malformedURLsAreNotLinks() {
        Self.expectNoLink([
            "https://example.com/?q=<script>",
            "https://example.com/a|b",
            "https://example.com/a^b`{}",
            "https://example.com/\"x\"",
            "https://example.com/a\\b",
            "https://example.com/100%",
            "https://example.com/a%zz",
            "https://example.com/a%2",
            "https://example.com/a[0]",
            "https://example.com/?ids[]=1",
            "https://example.com/#a#b",
            "https://[::1",
            "https://example.com:abc/"
        ])
    }

    /// The browser would decode `exa%6dple.com` and open `example.com`.
    @Test("A percent escape in the host is not a link")
    func escapedHostIsNotALink() {
        Self.expectNoLink([
            "https://exa%6dple.com/",
            "https://%41pple.com/",
            "https://%65%76%69%6C.example/",
            "http://[fe80::1%25en0]/"
        ])
    }

    /// On macOS 14 and later `openableURL` refuses these rows even without the check, because
    /// `URLComponents` escapes them and the result no longer equals the value. The check must not
    /// lean on that, so it is pinned on its own.
    @Test("The location check refuses what a URL cannot hold, without help from URLComponents")
    func locationCheckStandsAlone() {
        let refused = [
            "example.com/?q=<script>", "example.com/a|b", "example.com/a^b", "example.com/a`b", "example.com/{a}",
            "example.com/\"x\"", "example.com/a\\b", "example.com/a b", "example.com/100%", "example.com/a%zz",
            "example.com/a%2", "example.com/a[0]", "example.com/?ids[]=1", "example.com/#a#b", "exa%6dple.com/",
            "example.com/caf\u{00E9}", "exa\u{200B}mple.com/", "\u{0430}pple.com/"
        ]
        for location in refused {
            #expect(!DataLinkPolicy.isWellFormedLocation(location.unicodeScalars), "\(Self.visible(location))")
        }

        let allowed = [
            "example.com", "example.com/a?b=c#d", "[::1]:8080/x", "example.com/path%20with%20escapes",
            "example.com/a;b=c,d!e$f&g'h(i)j*k+l", "example.com/?a=b&c=d#frag/x?y", "example.com/~user/_x-y.z"
        ]
        for location in allowed {
            #expect(DataLinkPolicy.isWellFormedLocation(location.unicodeScalars), "\(location)")
        }
    }

    // MARK: - mailto

    @Test("mailto takes one address")
    func mailtoAddresses() {
        Self.expectLinks([
            "mailto:someone@example.com",
            "mailto:first.last+tag@sub.example.co.uk",
            "mailto:o'brien@example.com",
            "mailto:first_last@example.com",
            "mailto:root@localhost"
        ])
    }

    /// A query can add a hidden recipient, a body or an attachment to the message it opens.
    @Test("mailto with a query, a fragment or a percent escape is not a link")
    func mailtoQueryIsNotALink() {
        Self.expectNoLink([
            "mailto:a@b.com?bcc=evil@x.example",
            "mailto:a@b.com?subject=hi&body=x&bcc=evil@x.example",
            "mailto:a@b.com?attach=/etc/passwd",
            "mailto:a@b.com?subject=x%0D%0ABcc:evil@x.example",
            "mailto:?to=a@b.com",
            "mailto:a@b.com?",
            "mailto:a@b.com#x",
            "mailto:a%40b.com@c.com",
            "mailto:a@b.com%3Fbcc=evil@x.example",
            "mailto:a@b.com%0D%0ABcc:evil"
        ])
    }

    @Test("mailto without exactly one local part and one domain is not a link")
    func mailtoShape() {
        Self.expectNoLink([
            "mailto:", "mailto:@", "mailto:a@", "mailto:@b.com", "mailto:someone", "mailto:a@b@c.com",
            "mailto:a@b.com,c@d.com", "mailto:a@b.com;c@d.com", "mailto://a@b.com", "mailto:a@b.com/x", "mailto:a@b.com:25"
        ])
    }

    // MARK: - Length

    @Test("A value of 2,048 bytes is a link and one of 2,049 is not")
    func lengthGate() {
        let prefix = "https://example.com/"
        let atLimit = prefix + String(repeating: "a", count: DataLinkPolicy.maxLength - prefix.utf8.count)
        #expect(atLimit.utf8.count == 2_048)
        Self.expectLinks([atLimit])
        #expect(DataLinkPolicy.openableURL(from: atLimit + "a") == nil)
    }

    @Test("A 1 MB value that starts like a link is not a link")
    func megabyteValueIsNotALink() {
        #expect(DataLinkPolicy.openableURL(from: "https://example.com/" + String(repeating: "a", count: 1_048_576)) == nil)
    }

    // MARK: - Opening

    @Test("Open hands an allowed URL to the opener")
    @MainActor
    func openForwardsAllowedURLs() throws {
        let original = DataLinkPolicy.opener
        defer { DataLinkPolicy.opener = original }
        var opened: [URL] = []
        DataLinkPolicy.opener = { opened.append($0) }

        let web = try #require(DataLinkPolicy.openableURL(from: "https://example.com/a?b=c#d"))
        let mail = try #require(DataLinkPolicy.openableURL(from: "mailto:someone@example.com"))
        DataLinkPolicy.open(web)
        DataLinkPolicy.open(mail)

        #expect(opened.map(\.absoluteString) == ["https://example.com/a?b=c#d", "mailto:someone@example.com"])
    }

    @Test("Open refuses a URL the policy would not have produced")
    @MainActor
    func openRefusesOtherURLs() throws {
        let original = DataLinkPolicy.opener
        defer { DataLinkPolicy.opener = original }
        var opened: [URL] = []
        DataLinkPolicy.opener = { opened.append($0) }

        let refused = [
            "file:///etc/passwd",
            "tablepro://connect?host=evil",
            "postgres://user:pw@host/db",
            "javascript:alert(1)",
            "ftp://example.com/file",
            "https://apple.com@evil.example/login",
            "mailto:a@b.com?bcc=evil@x.example"
        ]
        for text in refused {
            let url = try #require(URL(string: text), "\(text)")
            DataLinkPolicy.open(url)
        }
        DataLinkPolicy.open(URL(fileURLWithPath: "/etc/passwd"))

        #expect(opened.isEmpty)
    }

    // MARK: - Cut values

    @Test("A cut head shows the destination once it runs through the host, port or not")
    func headThroughTheHostShowsTheDestination() throws {
        let url = try #require(DataLinkPolicy.openableURL(from: "https://example.com:8443/a/b"))

        #expect(DataLinkPolicy.showsDestination(of: url, in: "https://example.com"))
        #expect(DataLinkPolicy.showsDestination(of: url, in: "https://example.com:84"))
        #expect(DataLinkPolicy.showsDestination(of: url, in: "https://example.com:8443/a/b"))
    }

    @Test("A cut head that stops inside the host, or is not the start of the link, does not")
    func headInsideTheHostHidesTheDestination() throws {
        let url = try #require(DataLinkPolicy.openableURL(from: "https://example.com.attacker.example/a"))

        #expect(!DataLinkPolicy.showsDestination(of: url, in: "https://example.com"))
        #expect(!DataLinkPolicy.showsDestination(of: url, in: "https://"))
        #expect(!DataLinkPolicy.showsDestination(of: url, in: ""))
        #expect(!DataLinkPolicy.showsDestination(of: url, in: "http://example.com.attacker.example/a"))
        #expect(DataLinkPolicy.showsDestination(of: url, in: "https://example.com.attacker.example"))
    }

    @Test("A link with no host, like mailto, needs its whole address shown")
    func mailtoNeedsTheWholeAddress() throws {
        let url = try #require(DataLinkPolicy.openableURL(from: "mailto:ceo@example.com.attacker.example"))

        #expect(!DataLinkPolicy.showsDestination(of: url, in: "mailto:ceo@example.com"))
        #expect(DataLinkPolicy.showsDestination(of: url, in: "mailto:ceo@example.com.attacker.example"))
    }
}
