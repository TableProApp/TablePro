import TableProPluginKit
import Testing

struct MySQLLexicalFeaturesTests {
    @Test("NO_BACKSLASH_ESCAPES from the server status turns the backslash off in both string quotes")
    func mySQLSessionState() {
        let off = MySQLLexicalFeatures.features(for: .mysql, noBackslashEscapes: true)
        #expect(!off.contains(.backslashEscapesInSingleQuotes))
        #expect(!off.contains(.backslashEscapesInDoubleQuotes))
        #expect(MySQLLexicalFeatures.features(for: .mysql, noBackslashEscapes: false) == MySQLLexicalFeatures.mySQL)
        #expect(MySQLLexicalFeatures.sessionState(noBackslashEscapes: nil) == nil)
        #expect(MySQLLexicalFeatures.features(for: .databend, noBackslashEscapes: true) == MySQLLexicalFeatures.databend)
    }
}
