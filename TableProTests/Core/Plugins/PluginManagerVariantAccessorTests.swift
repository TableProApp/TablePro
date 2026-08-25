//
//  PluginManagerVariantAccessorTests.swift
//  TableProTests
//
//  A variant type (Redshift, CockroachDB, PGlite on the PostgreSQL plugin) has a curated entry
//  of its own. Every PluginManager accessor must answer from THAT entry, not from the entry of
//  the plugin that serves it.
//
//  PluginMetadataRegistryVariantTests already pins what registerVariant stores. These pin what
//  the accessors return, which is a different question and the one that was wrong: the registry
//  held the right values while ~70 call sites asked for them by pluginTypeId and were handed
//  PostgreSQL's instead. Both ends have to be pinned or the two can drift apart again.
//
//  No plugin loads under XCTest (AppDelegate guards loadPlugins on XCTestConfigurationFilePath),
//  so these read the curated built-in table directly, which is exactly what the app reads before
//  any plugin has loaded.
//

import Foundation
@testable import TablePro
import TableProPluginKit
import Testing

@Suite("PluginManager variant accessors")
@MainActor
struct PluginManagerVariantAccessorTests {
    private var manager: PluginManager { PluginManager.shared }

    @Test("PGlite is not offered transports its curated entry disables")
    func pgliteDeclinesTransportsItDoesNotSupport() {
        #expect(manager.supportsSSH(for: .pglite) == false)
        #expect(manager.supportsSSL(for: .pglite) == false)
        #expect(manager.supportsCloudflareTunnel(for: .pglite) == false)
        #expect(manager.supportsSOCKSProxy(for: .pglite) == false)
    }

    @Test("PostgreSQL keeps the transports PGlite declines, so the two are genuinely distinguished")
    func postgresKeepsItsOwnTransports() {
        #expect(manager.supportsSSH(for: .postgresql))
        #expect(manager.supportsSSL(for: .postgresql))
    }

    @Test("Redshift and CockroachDB name their own system databases")
    func variantsNameTheirOwnSystemDatabases() {
        #expect(manager.systemDatabaseNames(for: .redshift) == ["padb_harvest"])
        #expect(manager.systemDatabaseNames(for: .cockroachdb) == ["system"])
    }

    /// The reason the editor half of this was reported: Redshift has no non-ASCII ILIKE, so it
    /// folds case with a function instead. Reading PostgreSQL's dialect told it otherwise.
    @Test("Redshift folds case with a function, not PostgreSQL's ILIKE")
    func redshiftKeepsItsOwnCaseSensitivityStyle() throws {
        let redshift = try #require(manager.sqlDialect(for: .redshift))
        let postgres = try #require(manager.sqlDialect(for: .postgresql))
        #expect(redshift.caseSensitivityStyle == .caseFoldFunction)
        #expect(redshift.caseSensitivityStyle != postgres.caseSensitivityStyle)
    }

    /// The guard that generalises all of the above: an accessor that reads a snapshot must agree
    /// with `snapshot(for:)` for every known type. A new accessor written against `pluginTypeId`
    /// makes this fail on the variants rather than shipping silently.
    @Test("Every known type's accessors agree with its own snapshot")
    func accessorsAgreeWithTheTypesOwnSnapshot() {
        for type in DatabaseType.allKnownTypes {
            guard let snapshot = PluginMetadataRegistry.shared.snapshot(for: type) else { continue }
            #expect(
                manager.supportsSSH(for: type) == snapshot.capabilities.supportsSSH,
                "supportsSSH disagrees for \(type.rawValue)"
            )
            #expect(
                manager.supportsSSL(for: type) == snapshot.capabilities.supportsSSL,
                "supportsSSL disagrees for \(type.rawValue)"
            )
            #expect(
                manager.systemDatabaseNames(for: type) == snapshot.schema.systemDatabaseNames,
                "systemDatabaseNames disagrees for \(type.rawValue)"
            )
            #expect(
                manager.defaultSchemaName(for: type) == snapshot.schema.defaultSchemaName,
                "defaultSchemaName disagrees for \(type.rawValue)"
            )
        }
    }

    /// Deletion, Keychain cleanup and export redaction need a SUPERSET, because a connection saved
    /// while the variant was still being offered the primary's whole form can hold a secret under
    /// a field the variant never declared. Narrowing to what the form renders today would orphan
    /// that value in the Keychain and stop redacting it on export.
    @Test("Secure field ids stay a superset of the serving plugin's")
    func secureFieldIdsCoverTheServingPluginsFields() {
        let pglite = Set(manager.secureConnectionFieldIds(for: .pglite))
        let postgresSecure = Set(
            manager.additionalConnectionFields(for: .postgresql).filter(\.isSecure).map(\.id)
        )
        #expect(postgresSecure.isSubset(of: pglite))
    }

    /// The counterpart: rendering a form is the opposite requirement and stays exact, or PGlite
    /// gets `~/.pgpass`, the AWS IAM block and an RDS Endpoint field for an embedded WASM engine.
    @Test("The rendered form stays exact, so PGlite is not given PostgreSQL's fields")
    func renderedFormStaysExact() {
        let pgliteFields = manager.additionalConnectionFields(for: .pglite)
        let postgresFields = manager.additionalConnectionFields(for: .postgresql)
        #expect(pgliteFields.count < postgresFields.count)
    }
}
