//
//  PluginMetadataRegistry+SnapshotAdoption.swift
//  TablePro
//
//  How a curated built-in entry and a plugin's own snapshot combine. Every rule here is a named
//  single fact rather than a value diff: SQLDialectDescriptor is not Equatable, and a
//  whole-descriptor comparison would answer "differs" for a variant whose curated entry already
//  deviates, handing it back the entry the merge exists to replace.
//

import Foundation
import TableProPluginKit

extension PluginMetadataRegistry {
    /// The curated entry describes a variant's engine, not its grammar. Its editor config is a
    /// hand-written stub that exists so the app can answer before any plugin loads, and it is a
    /// fraction of what the plugin ships: the PostgreSQL plugin carries 559 keywords, 90 data
    /// types and an operator set against the stub's 84, 43, 28 and none. A variant therefore
    /// takes the plugin's editor config, and the curated entry keeps only the facts it states
    /// deliberately, meaning the ones where it differs from the curated primary.
    ///
    /// Two facts qualify: case-insensitive matching, which is why Redshift is spelled
    /// `postgresqlDialect.withCaseSensitivityStyle(.caseFoldFunction)`, and the column type list,
    /// which TiDB narrows (no spatial types) and Databend replaces with its own. Each has its own
    /// named adoption here rather than a value comparison: `SQLDialectDescriptor` is not
    /// `Equatable`, and a whole-descriptor diff would report "differs" for Redshift and hand it
    /// the stub back.
    static func adoptPluginEditorConfig(
        _ snapshot: inout PluginMetadataSnapshot,
        pluginSnapshot: PluginMetadataSnapshot,
        curatedPrimary: PluginMetadataSnapshot?
    ) {
        guard let pluginDialect = pluginSnapshot.editor.sqlDialect else { return }
        let curatedDialect = snapshot.editor.sqlDialect
        let curatedColumnTypes = snapshot.editor.columnTypesByCategory
        snapshot.editor = pluginSnapshot.editor

        if let primaryColumnTypes = curatedPrimary?.editor.columnTypesByCategory,
           curatedColumnTypes != primaryColumnTypes {
            snapshot.editor = PluginMetadataSnapshot.EditorConfig(
                sqlDialect: snapshot.editor.sqlDialect,
                statementCompletions: snapshot.editor.statementCompletions,
                columnTypesByCategory: curatedColumnTypes
            )
        }

        guard let curatedDialect,
              let primaryDialect = curatedPrimary?.editor.sqlDialect,
              curatedDialect.caseSensitivityStyle != primaryDialect.caseSensitivityStyle
              || curatedDialect.caseFoldFunction != primaryDialect.caseFoldFunction
        else { return }
        snapshot.editor.sqlDialect = pluginDialect.withCaseSensitivityStyle(
            curatedDialect.caseSensitivityStyle,
            caseFoldFunction: curatedDialect.caseFoldFunction
        )
    }

    /// A plugin built before case-insensitive matching existed reports `.unsupported`,
    /// which would leave its engine without the option until the plugin is re-released.
    /// The app's curated entry knows the engine, so it fills the gap.
    static func adoptCuratedCaseSensitivity(
        _ snapshot: inout PluginMetadataSnapshot,
        registryDefault: PluginMetadataSnapshot
    ) {
        guard let dialect = snapshot.editor.sqlDialect,
              dialect.caseSensitivityStyle == .unsupported,
              let curated = registryDefault.editor.sqlDialect,
              curated.caseSensitivityStyle != .unsupported else { return }
        snapshot.editor.sqlDialect = dialect.withCaseSensitivityStyle(
            curated.caseSensitivityStyle,
            caseFoldFunction: curated.caseFoldFunction
        )
    }

    static func adoptCuratedExplainVariants(
        _ snapshot: inout PluginMetadataSnapshot,
        registryDefault: PluginMetadataSnapshot
    ) {
        guard snapshot.explainVariants.isEmpty, !registryDefault.explainVariants.isEmpty else { return }
        snapshot = snapshot.withExplainVariants(registryDefault.explainVariants)
    }

    /// A name is a system database or schema when either the plugin or the app's curated entry lists it. An installed
    /// plugin can predate the app's list or report none at all: every published Oracle plugin lists no system
    /// schemas, which left `SYS` and `XDB` among the user schemas whichever plugin version was installed.
    static func adoptCuratedSystemNames(
        _ snapshot: inout PluginMetadataSnapshot,
        registryDefault: PluginMetadataSnapshot
    ) {
        let databases = mergedSystemNames(
            reported: snapshot.schema.systemDatabaseNames,
            curated: registryDefault.schema.systemDatabaseNames
        )
        let schemas = mergedSystemNames(
            reported: snapshot.schema.systemSchemaNames,
            curated: registryDefault.schema.systemSchemaNames
        )
        guard databases != snapshot.schema.systemDatabaseNames
            || schemas != snapshot.schema.systemSchemaNames else { return }
        snapshot = snapshot.withSystemNames(databases: databases, schemas: schemas)
    }

    private static func mergedSystemNames(reported: [String], curated: [String]) -> [String] {
        var seen = Set(reported)
        return reported + curated.filter { seen.insert($0).inserted }
    }

    /// A plugin built before its engine moved to schema-only switching still
    /// declares database switching with bySchema grouping. The app's registry
    /// default is the ground truth for routing, so its switch fields win.
    static func declaresLegacySchemaOnlyRouting(
        _ snapshot: PluginMetadataSnapshot,
        registryDefault: PluginMetadataSnapshot
    ) -> Bool {
        !registryDefault.supportsDatabaseSwitching
            && registryDefault.capabilities.supportsSchemaSwitching
            && snapshot.supportsDatabaseSwitching
            && snapshot.capabilities.supportsSchemaSwitching
            && snapshot.schema.databaseGroupingStrategy == .bySchema
    }
}
