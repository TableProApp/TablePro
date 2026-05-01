import Foundation
import Testing

@testable import TablePro

@Suite("MCP Tool Handler — identifier validation hardening")
struct MCPToolHandlerSecurityTests {
    @Test("validateExportTableName rejects double-dot")
    func rejectsDoubleDot() {
        do {
            try MCPToolHandler.validateExportTableName("schema..table")
            Issue.record("Expected throw for double-dot table name")
        } catch let error as MCPError {
            if case .invalidParams = error { return }
            Issue.record("Expected invalidParams, got \(error)")
        } catch {
            Issue.record("Expected MCPError, got \(error)")
        }
    }

    @Test("validateExportTableName rejects trailing dot")
    func rejectsTrailingDot() {
        do {
            try MCPToolHandler.validateExportTableName("schema.")
            Issue.record("Expected throw for trailing-dot table name")
        } catch let error as MCPError {
            if case .invalidParams = error { return }
            Issue.record("Expected invalidParams, got \(error)")
        } catch {
            Issue.record("Expected MCPError, got \(error)")
        }
    }

    @Test("validateExportTableName rejects only dots")
    func rejectsOnlyDots() {
        do {
            try MCPToolHandler.validateExportTableName("..")
            Issue.record("Expected throw for dots-only table name")
        } catch let error as MCPError {
            if case .invalidParams = error { return }
            Issue.record("Expected invalidParams, got \(error)")
        } catch {
            Issue.record("Expected MCPError, got \(error)")
        }
    }

    @Test("validateExportTableName accepts schema-qualified identifiers")
    func acceptsValidQualified() throws {
        try MCPToolHandler.validateExportTableName("public.users")
        try MCPToolHandler.validateExportTableName("db.schema.table")
    }

    @Test("quoteQualifiedIdentifier throws on empty component")
    func quoteThrowsOnEmptyComponent() {
        let quoter: (String) -> String = { "\"\($0)\"" }
        do {
            _ = try MCPToolHandler.quoteQualifiedIdentifier("schema..table", quoter: quoter)
            Issue.record("Expected throw for empty component in qualified identifier")
        } catch let error as MCPError {
            if case .invalidParams = error { return }
            Issue.record("Expected invalidParams, got \(error)")
        } catch {
            Issue.record("Expected MCPError, got \(error)")
        }
    }

    @Test("quoteQualifiedIdentifier throws on leading dot")
    func quoteThrowsOnLeadingDot() {
        let quoter: (String) -> String = { "\"\($0)\"" }
        do {
            _ = try MCPToolHandler.quoteQualifiedIdentifier(".table", quoter: quoter)
            Issue.record("Expected throw for leading-dot identifier")
        } catch let error as MCPError {
            if case .invalidParams = error { return }
            Issue.record("Expected invalidParams, got \(error)")
        } catch {
            Issue.record("Expected MCPError, got \(error)")
        }
    }

    @Test("quoteQualifiedIdentifier quotes each segment for valid identifiers")
    func quoteQuotesValidSegments() throws {
        let quoter: (String) -> String = { "\"\($0)\"" }
        let result = try MCPToolHandler.quoteQualifiedIdentifier("public.users", quoter: quoter)
        #expect(result == "\"public\".\"users\"")
    }
}
