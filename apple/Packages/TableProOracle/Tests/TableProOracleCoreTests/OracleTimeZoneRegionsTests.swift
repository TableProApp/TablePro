import Foundation
@testable import TableProOracleCore
import Testing

enum OracleTimeZoneRegionFixtures {
    // Bytes 11 and 12 of a Europe/Paris value measured on 23ai: region id 382.
    static let parisZone: (UInt8, UInt8) = (0x85, 0xf8)

    // A row as the map query returns it: 2000-01-01 00:00:00 UTC at the named zone.
    static func row(_ name: String, zone: (UInt8, UInt8)) -> (name: String, wire: [UInt8]) {
        (name, [0x78, 0x64, 0x01, 0x01, 0x01, 0x01, 0x01, 0x00, 0x00, 0x00, 0x00, zone.0, zone.1])
    }

    static let paris = OracleTimeZoneRegions(rows: [row("Europe/Paris", zone: parisZone)])
}

struct OracleTimeZoneRegionsTests {
    private static func wire(zone: (UInt8, UInt8)) -> [UInt8] {
        OracleTimeZoneRegionFixtures.row("", zone: zone).wire
    }

    @Test func testRegionIDSpansBytes11And12() {
        #expect(OracleTimeZoneRegions.regionID(wire: Self.wire(zone: OracleTimeZoneRegionFixtures.parisZone)) == 382)
        #expect(OracleTimeZoneRegions.regionID(wire: Self.wire(zone: (0xff, 0xfc))) == 8_191)
    }

    @Test func testRegionIDIgnoresTheLowBitsOfByte12() {
        #expect(OracleTimeZoneRegions.regionID(wire: Self.wire(zone: (0x85, 0xf9))) == 382)
        #expect(OracleTimeZoneRegions.regionID(wire: Self.wire(zone: (0x85, 0xfb))) == 382)
    }

    // The flag alone marks a region, so an id whose low six bits are zero is not read as a zero offset.
    @Test func testRegionIDWithAZeroByte12IsStillARegion() {
        #expect(OracleTimeZoneRegions.regionID(wire: Self.wire(zone: (0x85, 0x00))) == 320)
    }

    @Test func testOffsetZonesHaveNoRegionID() {
        #expect(OracleTimeZoneRegions.regionID(wire: Self.wire(zone: (0x14, 0x3c))) == nil)
        #expect(OracleTimeZoneRegions.regionID(wire: Self.wire(zone: (0x0f, 0x1e))) == nil)
        #expect(OracleTimeZoneRegions.regionID(wire: Self.wire(zone: (0x00, 0x00))) == nil)
        #expect(OracleTimeZoneRegions.regionID(wire: Array(Self.wire(zone: (0x85, 0xf8)).prefix(11))) == nil)
    }

    @Test func testMapDropsOffsetRowsAndKeepsTheFirstOfARepeatedID() throws {
        let regions = OracleTimeZoneRegions(rows: [
            OracleTimeZoneRegionFixtures.row("Europe/Paris", zone: OracleTimeZoneRegionFixtures.parisZone),
            OracleTimeZoneRegionFixtures.row("Europe/Monaco", zone: OracleTimeZoneRegionFixtures.parisZone),
            OracleTimeZoneRegionFixtures.row("UTC", zone: (0x14, 0x3c)),
        ])
        #expect(regions.count == 1)
        #expect(regions.duplicateIDs == 1)
        let paris = try #require(regions.region(forID: 382))
        #expect(paris.name == "Europe/Paris")
        #expect(paris.zone?.identifier == "Europe/Paris")
    }

    @Test func testMapKeepsANameFoundationDoesNotKnowWithoutAZone() throws {
        let regions = OracleTimeZoneRegions(rows: [
            OracleTimeZoneRegionFixtures.row("Not/AZone", zone: OracleTimeZoneRegionFixtures.parisZone),
        ])
        let region = try #require(regions.region(forID: 382))
        #expect(region.name == "Not/AZone")
        #expect(region.zone == nil)
        #expect(regions.unknownNames == 1)
    }

    @Test func testNoneHoldsNoRegions() {
        #expect(OracleTimeZoneRegions.none.isEmpty)
        #expect(OracleTimeZoneRegions(rows: []) == OracleTimeZoneRegions.none)
    }

    // A schema can hold its own V$TIMEZONE_NAMES, which an unqualified name resolves to first.
    @Test func testQueryReadsTheQualifiedPerformanceView() {
        #expect(OracleTimeZoneRegions.query.contains("SELECT DISTINCT TZNAME FROM SYS.V_$TIMEZONE_NAMES)"))
        #expect(OracleTimeZoneRegions.query.hasSuffix("ORDER BY TZNAME"))
    }
}
