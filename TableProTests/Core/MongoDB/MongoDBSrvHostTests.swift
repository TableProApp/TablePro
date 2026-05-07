//
//  MongoDBSrvHostTests.swift
//  TableProTests
//

import Foundation
@testable import TablePro
import Testing

@Suite("MongoDBConnection.stripPort(fromSrvHost:)")
struct MongoDBSrvHostTests {
    @Test("strips trailing :port from SRV host")
    func stripsTrailingPort() {
        let result = MongoDBConnection.stripPort(fromSrvHost: "tablepro.7uzbwhl.mongodb.net:27017")
        #expect(result == "tablepro.7uzbwhl.mongodb.net")
    }

    @Test("leaves bare host unchanged")
    func leavesBareHostUnchanged() {
        let result = MongoDBConnection.stripPort(fromSrvHost: "tablepro.7uzbwhl.mongodb.net")
        #expect(result == "tablepro.7uzbwhl.mongodb.net")
    }

    @Test("trims surrounding whitespace")
    func trimsWhitespace() {
        let result = MongoDBConnection.stripPort(fromSrvHost: "  cluster.mongodb.net:27017  ")
        #expect(result == "cluster.mongodb.net")
    }

    @Test("does not strip non-numeric trailing segment")
    func preservesNonNumericSuffix() {
        let result = MongoDBConnection.stripPort(fromSrvHost: "host.example.com:abc")
        #expect(result == "host.example.com:abc")
    }

    @Test("empty string passes through")
    func emptyHost() {
        #expect(MongoDBConnection.stripPort(fromSrvHost: "") == "")
    }
}
