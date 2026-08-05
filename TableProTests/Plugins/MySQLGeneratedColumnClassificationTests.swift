//
//  MySQLGeneratedColumnClassificationTests.swift
//  TableProTests
//

import Testing

@Suite("MySQL Generated Column Classification")
struct MySQLGeneratedColumnClassificationTests {
    @Test("STORED GENERATED is generated")
    func storedGenerated() {
        #expect(mysqlColumnIsGenerated(extra: "STORED GENERATED"))
    }

    @Test("VIRTUAL GENERATED is generated")
    func virtualGenerated() {
        #expect(mysqlColumnIsGenerated(extra: "VIRTUAL GENERATED"))
    }

    @Test("Lowercase variants are handled")
    func lowercaseVariants() {
        #expect(mysqlColumnIsGenerated(extra: "stored generated"))
        #expect(mysqlColumnIsGenerated(extra: "virtual generated"))
    }

    @Test("DEFAULT_GENERATED expression defaults are not generated columns")
    func defaultGenerated() {
        #expect(!mysqlColumnIsGenerated(extra: "DEFAULT_GENERATED"))
        #expect(!mysqlColumnIsGenerated(extra: "DEFAULT_GENERATED on update CURRENT_TIMESTAMP"))
    }

    @Test("Other Extra values are not generated columns")
    func otherExtraValues() {
        #expect(!mysqlColumnIsGenerated(extra: "auto_increment"))
        #expect(!mysqlColumnIsGenerated(extra: "on update CURRENT_TIMESTAMP"))
        #expect(!mysqlColumnIsGenerated(extra: ""))
        #expect(!mysqlColumnIsGenerated(extra: nil))
    }
}
