import Foundation
import TableProPluginKit
import TableProSQLGrammar

nonisolated extension SQLLexicalGrammar {
    // The kit's feature for each grammar fact; `SQLLexicalFeatureMappingTests` holds every fact to a partner. A fact only
    // the curated table sets, such as `cqlBatches`, has none: no plugin can declare it, and it never reaches one.
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

nonisolated extension SQLSessionLexicalFacts {
    init(pluginState: PluginSessionLexicalState) {
        self.init(
            determined: SQLLexicalGrammar(pluginFeatures: pluginState.determined),
            enabled: SQLLexicalGrammar(pluginFeatures: pluginState.enabled)
        )
    }
}
