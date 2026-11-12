//
//  CassandraWireTextTests.swift
//  TableProCassandraCoreTests
//

import Foundation
import TableProCassandraCore
import Testing

struct CassandraWireTextTests {
    // Foundation drops this mark, and the key without it names another row.
    @Test("A leading byte order mark stays part of the text")
    func byteOrderMarkIsKept() {
        let bytes: [UInt8] = [0xEF, 0xBB, 0xBF, 0x61, 0x62, 0x63]
        let fromData = CassandraWireText.text(Data(bytes))
        let fromBuffer = bytes.withUnsafeBytes { CassandraWireText.text($0) }
        #expect(fromData == "\u{FEFF}abc")
        #expect(fromBuffer == "\u{FEFF}abc")
        #expect(fromData.map { Array($0.utf8) } == bytes)
    }

    @Test("Text that is not UTF-8 is not read as text", arguments: [[0xFF], [0x61, 0xC3], [0xED, 0xA0, 0x80]] as [[UInt8]])
    func invalidText(bytes: [UInt8]) {
        #expect(CassandraWireText.text(Data(bytes)) == nil)
    }

    @Test("Empty and plain text read as written")
    func plainText() {
        #expect(CassandraWireText.text(Data()) == "")
        #expect(CassandraWireText.text(Data("héllo".utf8)) == "héllo")
    }
}
