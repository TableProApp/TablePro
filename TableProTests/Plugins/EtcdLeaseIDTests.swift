//
//  EtcdLeaseIDTests.swift
//  TableProTests
//

import Foundation
import Testing

struct EtcdLeaseIDTests {
    @Test("A Lease cell reads back as the lease it shows", arguments: [16, 0x7b, 12_345, 0x694d_77aa_1e77_5e08] as [Int64])
    func cellTextRoundTrips(leaseId: Int64) throws {
        let cellText = EtcdLeaseID.cellText(serverValue: String(leaseId))

        #expect(try EtcdCommandParser.parseLeaseId(cellText) == leaseId)
    }

    @Test("A granted or listed lease id reads back as the lease it shows")
    func hexTextRoundTrips() throws {
        #expect(try EtcdCommandParser.parseLeaseId(EtcdLeaseID.hexText(serverValue: "16")) == 16)
        #expect(EtcdLeaseID.hexText(serverValue: "unknown") == "unknown")
    }

    @Test("A lease shows as 0x-prefixed hex")
    func cellTextIsPrefixedHex() {
        #expect(EtcdLeaseID.cellText(serverValue: "16") == "0x10")
        #expect(EtcdLeaseID.cellText(serverValue: "123") == "0x7b")
    }

    @Test("A key with no lease has an empty Lease cell")
    func noLeaseIsEmpty() {
        #expect(EtcdLeaseID.cellText(serverValue: "0").isEmpty)
        #expect(EtcdLeaseID.cellText(serverValue: nil).isEmpty)
    }
}
