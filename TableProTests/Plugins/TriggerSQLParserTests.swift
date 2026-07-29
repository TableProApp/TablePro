//
//  TriggerSQLParserTests.swift
//  TableProTests
//
//  Tests for TriggerSQLParser timing/event extraction from CREATE TRIGGER text.
//

import TableProPluginKit
import Testing

@Suite("TriggerSQLParser")
struct TriggerSQLParserTests {
    @Test("Parses BEFORE INSERT")
    func beforeInsert() {
        let result = TriggerSQLParser.timingAndEvent(from: "CREATE TRIGGER t1 BEFORE INSERT ON users BEGIN END")
        #expect(result.timing == "BEFORE")
        #expect(result.event == "INSERT")
    }

    @Test("Parses AFTER UPDATE")
    func afterUpdate() {
        let result = TriggerSQLParser.timingAndEvent(from: "CREATE TRIGGER t1 AFTER UPDATE ON users BEGIN END")
        #expect(result.timing == "AFTER")
        #expect(result.event == "UPDATE")
    }

    @Test("Parses INSTEAD OF DELETE")
    func insteadOfDelete() {
        let result = TriggerSQLParser.timingAndEvent(from: "CREATE TRIGGER t1 INSTEAD OF DELETE ON v BEGIN END")
        #expect(result.timing == "INSTEAD OF")
        #expect(result.event == "DELETE")
    }

    @Test("Handles lowercase SQL")
    func lowercase() {
        let result = TriggerSQLParser.timingAndEvent(from: "create trigger t1 after delete on users begin end")
        #expect(result.timing == "AFTER")
        #expect(result.event == "DELETE")
    }

    @Test("Handles UPDATE OF columns")
    func updateOfColumns() {
        let result = TriggerSQLParser.timingAndEvent(from: "CREATE TRIGGER t1 BEFORE UPDATE OF name, email ON users BEGIN END")
        #expect(result.timing == "BEFORE")
        #expect(result.event == "UPDATE")
    }

    @Test("Trigger name containing a timing keyword does not mislead timing")
    func nameWithTimingKeyword() {
        let result = TriggerSQLParser.timingAndEvent(from: "CREATE TRIGGER before_log AFTER UPDATE ON users BEGIN END")
        #expect(result.timing == "AFTER")
        #expect(result.event == "UPDATE")
    }

    @Test("Trigger name containing an event keyword does not mislead event")
    func nameWithEventKeyword() {
        let result = TriggerSQLParser.timingAndEvent(from: "CREATE TRIGGER insert_audit AFTER DELETE ON users BEGIN END")
        #expect(result.timing == "AFTER")
        #expect(result.event == "DELETE")
    }

    @Test("Returns empty values when no timing or event present")
    func malformed() {
        let result = TriggerSQLParser.timingAndEvent(from: "SOME OTHER STATEMENT")
        #expect(result.timing.isEmpty)
        #expect(result.event.isEmpty)
    }
}
