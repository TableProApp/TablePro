import Foundation
import TableProPluginKit
import TableProSQLGrammar
import TableProSQLQuoting

// The one place a connection is matched to its grammar: the curated table, which wins for every engine TablePro ships;
// else what the plugin declares; then what the driver read from its session, which only chooses how a script is split
// for execution. The gates read every reading whatever the session says.
enum SQLLexicalResolver {
    static func readings(
        for databaseType: DatabaseType,
        session: PluginSessionLexicalState? = nil
    ) -> SQLLexicalReadings {
        SQLLexicalReadings.resolve(
            databaseTypeId: databaseType.rawValue,
            queryLanguage: queryLanguage(for: databaseType),
            declared: declaredGrammar(for: databaseType),
            session: session.map(SQLSessionLexicalFacts.init(pluginState:))
        )
    }

    // The grammar a script is split with for execution on `connectionId`, with the driver's session facts applied.
    @MainActor
    static func executionGrammar(for databaseType: DatabaseType, connectionId: UUID) -> SQLLexicalGrammar {
        readings(for: databaseType, session: sessionState(for: connectionId)).execution
    }

    // Read from the driver holding that database: a connection that keeps one session per database can hold different
    // session facts on each.
    @MainActor
    static func executionGrammar(for databaseType: DatabaseType, scope: DatabaseScope) -> SQLLexicalGrammar {
        readings(for: databaseType, session: DatabaseManager.shared.sessionDriver(holding: scope)?.sessionLexicalState)
            .execution
    }

    // The escapes a literal needs so the session reads it back as written: the session's answer once it settled
    // whether a backslash escapes, else the form no reading of the engine can end early.
    static func stringEscapes(
        for databaseType: DatabaseType,
        session: PluginSessionLexicalState? = nil
    ) -> SQLStringEscapes {
        let declared = declaredGrammar(for: databaseType)
        let language = queryLanguage(for: databaseType)
        // An engine nobody described answers from its dialect's own backslash flag, not from an ANSI guess.
        if declared == nil, SQLLexicalProfile.curated(forDatabaseTypeId: databaseType.rawValue) == nil,
           language.flatMap({ SQLLexicalProfile.curated(forQueryLanguage: $0) }) == nil {
            let backslash = PluginMetadataRegistry.shared.snapshot(for: databaseType)?.editor.sqlDialect?
                .requiresBackslashEscaping ?? false
            return SQLStringEscapes(backslashEscapes: backslash)
        }
        let escapes = SQLLexicalReadings.stringEscapes(
            databaseTypeId: databaseType.rawValue,
            queryLanguage: language,
            declared: declared,
            session: session.map(SQLSessionLexicalFacts.init(pluginState:))
        )
        return driverEscapes(escapes, for: databaseType)
    }

    // Kept text declares no sql_mode, and MySQL's own set reads back the same under either backslash rule.
    static func keptTextStringEscapes(
        for databaseType: DatabaseType,
        session: PluginSessionLexicalState?
    ) -> SQLStringEscapes {
        let unsettled = stringEscapes(for: databaseType)
        return unsettled == .mysql ? unsettled : stringEscapes(for: databaseType, session: session)
    }

    // MySQL's own set, as its driver and mysqldump write it.
    static func driverEscapes(_ escapes: SQLStringEscapes, for databaseType: DatabaseType) -> SQLStringEscapes {
        if databaseType == .mssql { return .sqlServer }
        guard escapes == .backslash, SqlDialect.from(databaseTypeId: databaseType.rawValue) == .mysql else {
            return escapes
        }
        return .mysql
    }

    // The grammar a driver's own escaper writes for, as a dump declares it to whoever reads it back.
    static func executionFeatures(
        for databaseType: DatabaseType,
        session: PluginSessionLexicalState?
    ) -> SQLLexicalFeatures {
        readings(for: databaseType, session: session).execution.pluginFeatures
    }

    @MainActor
    static func stringEscapes(for databaseType: DatabaseType, connectionId: UUID) -> SQLStringEscapes {
        stringEscapes(for: databaseType, session: sessionState(for: connectionId))
    }

    // Nil while `connectionId` has no driver.
    @MainActor
    static func sessionState(for connectionId: UUID) -> PluginSessionLexicalState? {
        DatabaseManager.shared.driver(for: connectionId)?.sessionLexicalState
    }

    private static func queryLanguage(for databaseType: DatabaseType) -> String? {
        guard case .custom(let language)? = PluginMetadataRegistry.shared.snapshot(for: databaseType)?.editorLanguage
        else { return nil }
        return language
    }

    private static func declaredGrammar(for databaseType: DatabaseType) -> SQLLexicalGrammar? {
        PluginMetadataRegistry.shared.snapshot(for: databaseType)?.editor.sqlDialect?.lexicalFeatures
            .map(SQLLexicalGrammar.init(pluginFeatures:))
    }
}

extension DatabaseType {
    var lexicalReadings: SQLLexicalReadings {
        SQLLexicalResolver.readings(for: self)
    }

    // The grammar this engine is split with when no session says otherwise.
    var lexicalGrammar: SQLLexicalGrammar {
        lexicalReadings.execution
    }
}
