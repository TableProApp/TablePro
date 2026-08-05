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

    @Test("An invisible generated column is still generated on MySQL")
    func mysqlInvisibleCombination() {
        #expect(mysqlColumnIsGenerated(extra: "VIRTUAL GENERATED INVISIBLE"))
        #expect(mysqlColumnIsGenerated(extra: "STORED GENERATED INVISIBLE"))
    }

    @Test("MariaDB separates combined attributes with a comma")
    func mariadbInvisibleCombination() {
        #expect(mysqlColumnIsGenerated(extra: "VIRTUAL GENERATED, INVISIBLE"))
        #expect(mysqlColumnIsGenerated(extra: "STORED GENERATED, INVISIBLE"))
    }

    @Test("MariaDB 10.1 and older report a bare marker")
    func mariadbLegacyMarkers() {
        #expect(mysqlColumnIsGenerated(extra: "VIRTUAL"))
        #expect(mysqlColumnIsGenerated(extra: "PERSISTENT"))
        #expect(mysqlColumnIsGenerated(extra: "persistent"))
    }

    @Test("MariaDB values that only look like a bare marker are not generated")
    func mariadbNonGeneratedValues() {
        #expect(!mysqlColumnIsGenerated(extra: "on update current_timestamp()"))
        #expect(!mysqlColumnIsGenerated(extra: "auto_increment, INVISIBLE"))
        #expect(!mysqlColumnIsGenerated(extra: "INVISIBLE"))
        #expect(!mysqlColumnIsGenerated(extra: "WITHOUT SYSTEM VERSIONING"))
    }
}
