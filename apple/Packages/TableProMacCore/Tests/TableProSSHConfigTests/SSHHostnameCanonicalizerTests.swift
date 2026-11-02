//
//  SSHHostnameCanonicalizerTests.swift
//  TableProTests
//

import Foundation
import Testing

@testable import TableProSSHConfig

struct SSHHostnameCanonicalizerTests {
    private func canonicalize(
        _ host: String,
        permittedCNAMEs: String?,
        fallbackLocal: Bool = true,
        resolver: (String) -> String?
    ) -> String? {
        let options = SSHCanonicalizationOptions(
            mode: .yes,
            domains: ["corp.example"],
            fallbackLocal: fallbackLocal,
            maxDots: 1,
            permittedCNAMEs: permittedCNAMEs
        )
        return SSHHostnameCanonicalizer.canonicalize(host: host, options: options, resolver: resolver)
    }

    private func canonicalize(_ host: String, permittedCNAMEs: String?, cname: String) -> String? {
        canonicalize(host, permittedCNAMEs: permittedCNAMEs) { _ in cname }
    }

    @Test("A CNAME is not followed when no CanonicalizePermittedCNAMEs rule is set")
    func cnameIsNotFollowedByDefault() {
        #expect(canonicalize("db", permittedCNAMEs: nil, cname: "staging.vendor.example") == "db.corp.example")
    }

    @Test("A CNAME no rule covers is not followed", arguments: [
        "none",
        "*.corp.example:*.corp.example",
        "*.other.example:*.vendor.example",
        "*.corp.example:*,!*.vendor.example",
        "*.corp.example",
        "*.corp.example:",
        ":*.vendor.example",
    ])
    func cnameOutsideTheRulesIsNotFollowed(rules: String) {
        #expect(canonicalize("db", permittedCNAMEs: rules, cname: "staging.vendor.example") == "db.corp.example")
    }

    @Test("A bracket in a rule is a literal character, as in ssh")
    func bracketInARuleIsLiteral() {
        let rules = "*.corp.example:db[12].vendor.example"
        #expect(canonicalize("db", permittedCNAMEs: rules, cname: "db1.vendor.example") == "db.corp.example")
        #expect(canonicalize("db", permittedCNAMEs: rules, cname: "db[12].vendor.example") == "db.corp.example")
    }

    @Test("A CNAME a rule covers is followed", arguments: [
        "*",
        "*:*",
        "*.corp.example:*.internal.example",
        "*.CORP.example:*.Internal.Example",
        "*.other.example:*.other.example *.corp.example:*.dmz.example,*.internal.example",
    ])
    func permittedCNAMEIsFollowed(rules: String) {
        #expect(canonicalize("db", permittedCNAMEs: rules, cname: "db-7.internal.example") == "db-7.internal.example")
    }

    @Test("A CNAME may start with an underscore, as valid_domain allows")
    func underscoreCNAMEIsFollowed() {
        #expect(canonicalize("db", permittedCNAMEs: "*", cname: "_ssh.internal.example") == "_ssh.internal.example")
    }

    @Test("A CNAME that is not a valid domain name is never followed", arguments: [
        "", "db\n.internal.example", "db$(id).internal.example", "db[12].internal.example", "-db.internal.example",
        "db..internal.example", "bücher.internal.example"
    ])
    func invalidCNAMEIsNotFollowed(cname: String) {
        #expect(canonicalize("db", permittedCNAMEs: "*", cname: cname) == "db.corp.example")
    }

    @Test("An address is never canonicalized", arguments: ["fd00::5", "fe80::1%en0", "10.0.0.5", "127.1", "2130706433"])
    func addressIsLeftAlone(host: String) {
        #expect(canonicalize(host, permittedCNAMEs: "*", fallbackLocal: false) { _ in "elsewhere.example" } == host)
    }

    @Test("An anchored name is looked up as it is, before MaxDots and the domains")
    func anchoredNameIsLookedUpDirectly() {
        var asked: [String] = []
        let found = canonicalize("db.corp.example.", permittedCNAMEs: nil, fallbackLocal: false) { name in
            asked.append(name)
            return name == "db.corp.example" ? name : nil
        }
        #expect(found == "db.corp.example")
        #expect(asked == ["db.corp.example"])
        #expect(canonicalize("gone.example.", permittedCNAMEs: nil, fallbackLocal: false) { _ in nil } == nil)
        #expect(canonicalize("gone.example.", permittedCNAMEs: nil, fallbackLocal: true) { _ in nil } == "gone.example.")
        #expect(canonicalize("db.corp.example.", permittedCNAMEs: "*", cname: "db-7.internal.example") == "db-7.internal.example")
        #expect(canonicalize("db.corp.example.", permittedCNAMEs: nil, cname: "db-7.internal.example") == "db.corp.example")
    }

    @Test("CanonicalizeFallbackLocal no answers nil when no candidate resolves")
    func fallbackLocalNoAnswersNil() {
        #expect(canonicalize("db", permittedCNAMEs: nil, fallbackLocal: false) { _ in nil } == nil)
        #expect(canonicalize("db", permittedCNAMEs: nil, fallbackLocal: true) { _ in nil } == "db")
    }

    @Test("CanonicalizePermittedCNAMEs reaches the canonicalizer from the config")
    func rulesComeFromTheConfig() {
        func resolvedHost(rules: String) -> String {
            let env = ResolverEnvironment(
                runShell: { _ in true },
                canonicalize: { host, options in
                    SSHHostnameCanonicalizer.canonicalize(host: host, options: options) { _ in "db-7.internal.example" }
                },
                currentLocalUser: { "tester" }
            )
            let document = SSHConfigParser.parseDocumentContent("""
            CanonicalizeHostname yes
            CanonicalDomains corp.example
            \(rules)
            """)
            let config = SSHConfiguration(enabled: true, host: "db")
            return SSHConfigResolver.resolve(config, document: document, env: env).host
        }

        #expect(resolvedHost(rules: "") == "db.corp.example")
        #expect(resolvedHost(rules: "CanonicalizePermittedCNAMEs *.corp.example:*.vendor.example") == "db.corp.example")
        #expect(resolvedHost(rules: "CanonicalizePermittedCNAMEs *.corp.example:*.internal.example") == "db-7.internal.example")
    }
}
