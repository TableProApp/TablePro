//
//  RedisConnectionFieldsTests.swift
//  TableProTests
//

import Foundation
@testable import TablePro
import TableProPluginKit
import Testing

@Suite("Redis connection fields")
struct RedisConnectionFieldsTests {
    private func redisFields() throws -> [ConnectionField] {
        let snapshot = try #require(PluginMetadataRegistry.shared.snapshot(forRegisteredTypeId: "Redis"))
        return snapshot.connection.additionalConnectionFields
    }

    @Test("The mode picker offers all three topologies and starts on standalone")
    func modePicker() throws {
        let mode = try #require(try redisFields().first { $0.id == "redisMode" })
        #expect(mode.defaultValue == "standalone")
        #expect(mode.section == .connection)
        guard case .dropdown(let options) = mode.fieldType else {
            Issue.record("Expected a dropdown")
            return
        }
        #expect(options.map(\.value) == ["standalone", "sentinel", "cluster"])
    }

    @Test("Sentinel and Cluster each get their own host list")
    func hostLists() throws {
        let fields = try redisFields()
        let sentinelHosts = try #require(fields.first { $0.id == "redisSentinelHosts" })
        let clusterHosts = try #require(fields.first { $0.id == "redisClusterHosts" })

        for field in [sentinelHosts, clusterHosts] {
            guard case .hostList = field.fieldType else {
                Issue.record("\(field.id) should be a host list")
                return
            }
            #expect(field.isRequired)
            #expect(field.section == .connection)
        }
        #expect(sentinelHosts.placeholder == "127.0.0.1:26379")
        #expect(clusterHosts.placeholder == "127.0.0.1:6379")
    }

    @Test("Each mode-specific field is bound to its own mode")
    func visibilityRules() throws {
        let fields = try redisFields()
        let expected: [String: [String]] = [
            "redisSentinelHosts": ["sentinel"],
            "redisSentinelMasterName": ["sentinel"],
            "redisSentinelUsername": ["sentinel"],
            "redisSentinelPassword": ["sentinel"],
            "redisClusterHosts": ["cluster"],
            "redisDatabase": ["standalone", "sentinel"],
        ]
        for (id, values) in expected {
            let field = try #require(fields.first { $0.id == id })
            let rule = try #require(field.visibleWhen)
            #expect(rule.fieldId == "redisMode")
            #expect(rule.values == values)
        }
    }

    @Test("The Sentinel password is secure, so it is stored in the Keychain")
    func sentinelPasswordIsSecure() throws {
        let password = try #require(try redisFields().first { $0.id == "redisSentinelPassword" })
        #expect(password.isSecure)
    }

    /// Only the authentication pane reads secure values back out of the Keychain, so a secure field
    /// declared in another section is written once and then cleared on the next save.
    @Test("Every secure field on every plugin type sits in the authentication section")
    func secureFieldsLiveUnderAuthentication() {
        for entry in PluginMetadataRegistry.shared.registryPluginDefaults() {
            for field in entry.snapshot.connection.additionalConnectionFields where field.isSecure {
                #expect(
                    field.section == .authentication,
                    "\(entry.typeId).\(field.id) is secure but sits in \(field.section)"
                )
            }
        }
    }

    @Test("Key Separator and the ElastiCache IAM fields are declared")
    func legacyFieldsSurvive() throws {
        let ids = try redisFields().map(\.id)
        #expect(ids.contains("redisSeparator"))
        #expect(ids.contains("awsAuth"))
        #expect(ids.contains("awsReplicationGroupId"))
    }
}

@Suite("Connection field visibility across panes")
struct ConnectionFieldCrossPaneVisibilityTests {
    private let mode = ConnectionField(
        id: "redisMode",
        label: "Connection Mode",
        defaultValue: "standalone",
        fieldType: .dropdown(options: [
            .init(value: "standalone", label: "Standalone"),
            .init(value: "sentinel", label: "Sentinel"),
        ]),
        section: .connection
    )

    private let sentinelPassword = ConnectionField(
        id: "redisSentinelPassword",
        label: "Sentinel Password",
        fieldType: .secure,
        section: .authentication,
        visibleWhen: FieldVisibilityRule(fieldId: "redisMode", values: ["sentinel"])
    )

    @Test("A rule pointing at another section resolves against the merged values")
    func resolvesAcrossSections() {
        let fields = [mode, sentinelPassword]
        #expect(!fields.isVisible(sentinelPassword, forValues: [:]))
        #expect(fields.isVisible(sentinelPassword, forValues: ["redisMode": "sentinel"]))
        #expect(!fields.isVisible(sentinelPassword, forValues: ["redisMode": "standalone"]))
    }

    @Test("A field with no rule is always visible")
    func unconditionalFieldIsVisible() {
        #expect([mode].isVisible(mode, forValues: [:]))
    }

    @Test("An absent value falls back to the controlling field's default")
    func fallsBackToDefault() {
        let alwaysOn = ConnectionField(
            id: "x",
            label: "X",
            section: .advanced,
            visibleWhen: FieldVisibilityRule(fieldId: "redisMode", values: ["standalone"])
        )
        #expect([mode, alwaysOn].isVisible(alwaysOn, forValues: [:]))
    }
}
