//
//  SQLLexicalResolver.swift
//  TablePro
//

import Foundation
import TableProPluginKit
import TableProSQLGrammar

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
        let session = DatabaseManager.shared.driver(for: connectionId)?.sessionLexicalState
        return readings(for: databaseType, session: session).execution
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
    /// which is which, and `SQLLexicalFeatureMappingTests` holds every fact to a partner.
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
