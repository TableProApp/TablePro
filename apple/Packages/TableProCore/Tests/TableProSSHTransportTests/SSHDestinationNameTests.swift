import Foundation
import Testing

@testable import TableProSSHTransport

struct SSHDestinationNameTests {
    @Test("A host ssh or the shell would misread is refused", arguments: [
        "db$(touch /tmp/pwned).internal.example",
        "db`touch /tmp/pwned`.internal.example",
        "db;touch /tmp/pwned;.internal.example",
        "db|sh.internal.example",
        "db.internal.example\\",
        "db\n.internal.example",
        "replica.attacker.example\n[prod.corp.example",
        "db .example.com",
        "db\t.example.com",
        "db\r.example.com",
        "db\u{202E}.example.com",
        "-oProxyCommand=touch /tmp/pwned",
        "db'x.example.com",
        "db\"x.example.com",
        "db,evil.example",
        "",
        " bastion ",
        "a$b",
        "a*",
        "a?",
        "a[1]",
        "a#b",
        "#corp.example",
        "jump*",
        "!a",
        "a!b",
        "a\\b",
        "a\u{1}b",
        "a\u{7F}b",
        "[::1",
        "::1]",
        "[[::1]]",
        "[]",
        "[-a]",
        "a\u{200B}b",
        "a\u{A0}b",
        "a\u{2028}b",
        "a\u{AD}b",
        "a\u{FEFF}b",
        "a&b",
        "a<b",
        "a(b",
        "a{b",
        "db\u{37E}id.example.com",
        "db\u{1FEF}id\u{1FEF}.example.com",
    ])
    func hostileHostIsRefused(host: String) {
        #expect(!SSHDestinationName.isValidHost(host))
        #expect(SSHDestinationName.problem(host: host, user: "deploy") == .host(host))
    }

    @Test("A host ssh accepts is accepted", arguments: [
        "db.example.com",
        "10.0.0.5",
        "fe80::1%en0",
        "[fd00::5]",
        "::1",
        "bücher.example",
        "café",
        "db_1.example.com",
        "db.corp.example.",
        "a/b",
        "../x",
        "~a",
        "a:b",
        "a@b",
        "a^b",
        "a=b",
    ])
    func ordinaryHostIsAccepted(host: String) {
        #expect(SSHDestinationName.isValidHost(host))
    }

    @Test("A user ssh or the shell would misread is refused", arguments: [
        "x; touch /tmp/pwned; true",
        "x$(touch /tmp/pwned)",
        "x\ntouch /tmp/pwned",
        "-oProxyCommand=touch /tmp/pwned",
        "x -oProxyCommand=touch",
        "x\\",
        "x\u{0}y",
        "x\ty",
        "first last",
        "bob,evil.example.net",
        "backup$",
        " deploy",
        "a \\-o",
        "a*",
        "a?",
        "a[1]",
        "a#",
        "#a",
        "deploy #",
        "a\u{7F}",
        "a\u{200B}",
        "a\u{A0}b",
        "a\u{FEFF}",
        "a\u{202E}b",
        "a'b",
        "a(b",
        "deploy\u{37E}id",
        "deploy\u{1FEF}id\u{1FEF}",
    ])
    func hostileUserIsRefused(user: String) {
        #expect(!SSHDestinationName.isValidUser(user))
        #expect(SSHDestinationName.problem(host: "db.example.com", user: user) == .user(user))
    }

    @Test("A user ssh accepts is accepted, and an empty one is unset", arguments: [
        "deploy",
        "DOMAIN\\deploy",
        "user@realm",
        "!a",
        "a:b",
        "a%b",
        "a~",
        "",
    ])
    func ordinaryUserIsAccepted(user: String) {
        #expect(SSHDestinationName.isValidUser(user))
        #expect(SSHDestinationName.problem(host: "db.example.com", user: user) == nil)
    }

    // Process hands arguments over decomposed, where these two become `;` and a backtick.
    @Test("A scalar that decomposes into shell punctuation is refused", arguments: ["\u{37E}", "\u{1FEF}"])
    func decomposedPunctuationIsRefused(scalar: String) {
        #expect(!SSHDestinationName.isValidHost("db\(scalar)id"))
        #expect(!SSHDestinationName.isValidUser("deploy\(scalar)id"))
    }

    @Test("A port outside 1 to 65535 is refused", arguments: [0, -1, 65_536, 2_147_483_648])
    func outOfRangePortIsRefused(port: Int) {
        #expect(!SSHDestinationName.isValidPort(port))
        #expect(SSHDestinationName.problem(host: "db.example.com", user: "deploy", port: port) == .port(port))
    }

    @Test("A port in range, or none, is accepted", arguments: [Int?.none, 1, 22, 65_535])
    func portInRangeIsAccepted(port: Int?) {
        #expect(SSHDestinationName.problem(host: "db.example.com", user: "deploy", port: port) == nil)
    }

    @Test("The names are checked before the port")
    func namesAreCheckedBeforeThePort() {
        #expect(SSHDestinationName.problem(host: "a;b", user: "deploy", port: 0) == .host("a;b"))
        #expect(SSHDestinationName.problem(host: "db.example.com", user: "a b", port: 0) == .user("a b"))
    }

    @Test("The explanation names the refused value")
    func explanationNamesTheValue() {
        #expect(SSHDestinationName.Problem.host("a;b").explanation.contains("a;b"))
        #expect(SSHDestinationName.Problem.user("c|d").explanation.contains("c|d"))
        #expect(SSHDestinationName.Problem.port(70_000).explanation.contains("70000"))
        #expect(SSHDestinationName.Problem.host("").explanation == String(localized: "The SSH host is empty."))
    }
}
