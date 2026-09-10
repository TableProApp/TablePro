import Foundation
@testable import TableProMobile
import TableProModels
import TableProOracleCore
import Testing

@Suite("Oracle identifier mismatch classification")
struct OracleErrorClassifierTests {
    private struct ServerError: LocalizedError {
        let text: String
        var errorDescription: String? { text }
    }

    private func classify(_ message: String, type: DatabaseType) -> AppError {
        ErrorClassifier.classify(
            ServerError(text: message),
            context: ErrorContext(operation: "connect", databaseType: type, host: "db.example.com")
        )
    }

    @Test("ORA-12514 was sent a service name, so SID is the suggested fallback")
    func serviceNameNotRegistered() {
        let error = classify(
            "Service ORCL is not registered with the listener at db.example.com:1521. (ORA-12514).",
            type: .oracle
        )
        #expect(error.suggestedOracleMode == .sid)
        #expect(error.category == .config)
        #expect(error.recovery != nil)
    }

    @Test("ORA-12505 was sent a SID, so Service Name is the suggested fallback")
    func sidNotRegistered() {
        let error = classify(
            "TNS:listener does not currently know of SID given in connect descriptor (ORA-12505).",
            type: .oracle
        )
        #expect(error.suggestedOracleMode == .service)
        #expect(error.category == .config)
    }

    @Test("The same text on another engine never suggests an Oracle mode")
    func onlyAppliesToOracle() {
        let error = classify("ORA-12514 lookalike in a Postgres message", type: .postgresql)
        #expect(error.suggestedOracleMode == nil)
    }

    @Test("Unrelated Oracle failures carry no mode suggestion")
    func otherOracleErrorsAreUnaffected() {
        let error = classify("ORA-01017: invalid credential or not authorized; logon denied", type: .oracle)
        #expect(error.suggestedOracleMode == nil)
    }
}
