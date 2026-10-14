@testable import TableProAutocomplete
import TableProSQLGrammar

// Autocomplete tests name no engine, so they read standard SQL.
extension SQLContextAnalyzer {
    func analyze(query: String, cursorPosition: Int) -> SQLContext {
        analyze(query: query, cursorPosition: cursorPosition, grammar: .ansi)
    }
}
