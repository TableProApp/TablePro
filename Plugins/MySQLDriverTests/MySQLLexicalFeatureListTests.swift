//
//  MySQLLexicalFeatureListTests.swift
//  MySQLDriverTests
//

import Foundation
import TableProPluginKit
import Testing

// TableProTests' SQLLexicalFeatureMappingTests holds the app's curated MySQL and Databend grammars to these sets.
struct MySQLLexicalFeatureListTests {
    @Test("The grammars the plugin keeps are the sets the app's curated table is held to")
    func featureSetsArePinned() {
        #expect(MySQLLexicalFeatures.mySQL == [
            .backslashEscapesInSingleQuotes, .backslashEscapesInDoubleQuotes, .backtickQuotes, .hashLineComments,
            .executableComments, .dashCommentsNeedWhitespace, .delimiterDirective,
        ])
        #expect(MySQLLexicalFeatures.databend == [
            .backslashEscapesInSingleQuotes, .backslashEscapesInDoubleQuotes, .backtickQuotes, .untaggedDollarQuotes,
        ])
    }
}
