//
//  SQLLexicalResolver.swift
//  TablePro
//

import Foundation
import TableProPluginKit
import TableProSQLGrammar
import TableProSQLQuoting

/// The one place a connection is matched to the grammar its engine lexes with.
///
/// Three sources, in order: the curated table in `TableProSQLGrammar`, which both apps read and which wins for every
/// engine TablePro ships; what a plugin for any other engine declares on its `SQLDialectDescriptor`; and what the
/// connected driver read from its own session. The last only chooses how a script is split for execution. The gates
/// read ``SQLLexicalReadings/all`` whatever the session says.
enum SQLLexicalResolver {
    static func readings(
        for databaseType: DatabaseType,
        session: PluginSessionLexicalState? = nil
    ) -> SQLLexicalReadings {
        SQLLexicalReadings.resolve(
            databaseTypeId: databaseType.rawValue,
            declared: declaredGrammar(for: databaseType),
            session: session.map(SQLSessionLexicalFacts.init(pluginState:))
        )
    }

    /// The grammar a script is split with for execution on `connectionId`, with the driver's session facts applied.
    @MainActor
    static func executionGrammar(for databaseType: DatabaseType, connectionId: UUID) -> SQLLexicalGrammar {
        readings(for: databaseType, session: sessionState(for: connectionId)).execution
    }

    /// The grammar for text bound to `scope`, read from the driver holding that database: a connection that keeps one
    /// session per database can hold different session facts on each.
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
        // An engine nobody described answers from its dialect's own backslash flag, not from an ANSI guess.
        if declared == nil, SQLLexicalProfile.curated(forDatabaseTypeId: databaseType.rawValue) == nil {
            let backslash = PluginMetadataRegistry.shared.snapshot(for: databaseType)?.editor.sqlDialect?
                .requiresBackslashEscaping ?? false
            return SQLStringEscapes(backslashEscapes: backslash)
        }
        let escapes = SQLLexicalReadings.stringEscapes(
            databaseTypeId: databaseType.rawValue,
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

    /// What the connected driver read from its session, or `nil` while `connectionId` has none.
    @MainActor
    static func sessionState(for connectionId: UUID) -> PluginSessionLexicalState? {
        DatabaseManager.shared.driver(for: connectionId)?.sessionLexicalState
    }

    private static func declaredGrammar(for databaseType: DatabaseType) -> SQLLexicalGrammar? {
        PluginMetadataRegistry.shared.snapshot(for: databaseType)?.editor.sqlDialect?.lexicalFeatures
            .map(SQLLexicalGrammar.init(pluginFeatures:))
    }
}

extension DatabaseType {
    /// Every way this engine could lex a text, for a gate.
    var lexicalReadings: SQLLexicalReadings {
        SQLLexicalResolver.readings(for: self)
    }

    /// The grammar this engine is split with when no session says otherwise.
    var lexicalGrammar: SQLLexicalGrammar {
        lexicalReadings.execution
    }
}

extension SQLLexicalGrammar {
    /// The kit's feature for each grammar fact. The two sets carry the same bits by design; this table is what says
    /// which is which, and `SQLLexicalFeatureMappingTests` holds every fact to a partner. A fact only the curated
    /// table sets, such as `cqlBatches`, has none: no plugin can declare it, and it never reaches one.
    static let pluginFeaturePairs: [(SQLLexicalFeatures, SQLLexicalGrammar)] = [
        (.backslashEscapesInSingleQuotes, .backslashEscapesInSingleQuotes),
        (.backslashEscapesInDoubleQuotes, .backslashEscapesInDoubleQuotes),
        (.backslashEscapesInBackticks, .backslashEscapesInBackticks),
        (.backtickQuotes, .backtickQuotes),
        (.bracketQuotedIdentifiers, .bracketQuotedIdentifiers),
        (.tripleQuotedStrings, .tripleQuotedStrings),
        (.escapeStringPrefix, .escapeStringPrefix),
        (.alternativeQuoting, .alternativeQuoting),
        (.untaggedDollarQuotes, .untaggedDollarQuotes),
        (.taggedDollarQuotes, .taggedDollarQuotes),
        (.nestedBlockComments, .nestedBlockComments),
        (.hashLineComments, .hashLineComments),
        (.doubleSlashLineComments, .doubleSlashLineComments),
        (.executableComments, .executableComments),
        (.slashLineTerminators, .slashLineTerminators),
        (.dollarAndHashInIdentifiers, .dollarAndHashInIdentifiers),
        (.plsqlBlocks, .plsqlBlocks),
        (.delimiterDirective, .delimiterDirective),
        (.dashCommentsNeedWhitespace, .dashCommentsNeedWhitespace),
        (.parenthesizedParameterNames, .parenthesizedParameterNames),
        (.doubledClosingBracketEscapes, .doubledClosingBracketEscapes),
        (.carriageReturnEndsLineComments, .carriageReturnEndsLineComments),
        (.batchSeparatorLines, .batchSeparatorLines),
        (.unterminatedStatements, .unterminatedStatements),
        (.terminatedMergeStatements, .terminatedMergeStatements),
    ]

    init(pluginFeatures: SQLLexicalFeatures) {
        self = Self.pluginFeaturePairs.reduce(into: []) { grammar, pair in
            if pluginFeatures.contains(pair.0) { grammar.insert(pair.1) }
        }
    }

    var pluginFeatures: SQLLexicalFeatures {
        Self.pluginFeaturePairs.reduce(into: []) { features, pair in
            if contains(pair.1) { features.insert(pair.0) }
        }
    }
}

extension SQLSessionLexicalFacts {
    init(pluginState: PluginSessionLexicalState) {
        self.init(
            determined: SQLLexicalGrammar(pluginFeatures: pluginState.determined),
            enabled: SQLLexicalGrammar(pluginFeatures: pluginState.enabled)
        )
    }
}
