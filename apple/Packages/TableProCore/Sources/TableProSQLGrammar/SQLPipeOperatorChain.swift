import Foundation

// Snowflake runs each statement `->>` chains: `SHOW TABLES ->> DROP TABLE t` runs both. Not measured.
public enum SQLPipeOperatorChain {
    static let pipe = "->>"

    public static func statements(in statement: String, grammar: SQLLexicalGrammar) -> [String] {
        guard grammar.contains(.pipeOperatorChains) else { return [] }
        let text = statement as NSString
        let code = SQLCodeProjection.code(of: statement, grammar: grammar) as NSString
        var links: [String] = []
        var start = 0
        var chained = false
        while true {
            let pipe = code.range(of: pipe, options: .literal, range: NSRange(location: start, length: code.length - start))
            let end = pipe.location == NSNotFound ? code.length : pipe.location
            let link = NSRange(location: start, length: end - start)
            if StatementBlank.hasContent(code.substring(with: link)) {
                links.append(text.substring(with: link))
            }
            guard pipe.location != NSNotFound else { break }
            chained = true
            start = NSMaxRange(pipe)
        }
        return chained ? links : []
    }
}
