import Foundation

// A TIMESTAMP WITH TIME ZONE stored with a region name carries an id into the server's time zone file, which a
// thin client does not have, so the names are read from the server once per connection.
public struct OracleTimeZoneRegions: Sendable, Equatable {
    public struct Region: Sendable, Equatable {
        public let name: String
        public let zone: TimeZone?
    }

    public static let none = OracleTimeZoneRegions(regions: [:], duplicateIDs: 0)

    // AT TIME ZONE converts an instant, so no name can fail on a wall clock its zone skips.
    public static let query = "SELECT TZNAME, TIMESTAMP '2000-01-01 00:00:00 UTC' AT TIME ZONE TZNAME FROM "
        + "(SELECT DISTINCT TZNAME FROM \(OracleDictionary.performanceView("V$TIMEZONE_NAMES"))) ORDER BY TZNAME"

    private static let regionFlag: UInt8 = 0x80

    let regions: [Int: Region]
    let duplicateIDs: Int

    private init(regions: [Int: Region], duplicateIDs: Int) {
        self.regions = regions
        self.duplicateIDs = duplicateIDs
    }

    public init(rows: [(name: String, wire: [UInt8])]) {
        var regions: [Int: Region] = [:]
        var duplicateIDs = 0
        for row in rows {
            guard let id = Self.regionID(wire: row.wire) else { continue }
            guard regions[id] == nil else {
                duplicateIDs += 1
                continue
            }
            regions[id] = Region(name: row.name, zone: TimeZone(identifier: row.name))
        }
        self.init(regions: regions, duplicateIDs: duplicateIDs)
    }

    public var isEmpty: Bool {
        regions.isEmpty
    }

    public var count: Int {
        regions.count
    }

    var unknownNames: Int {
        regions.values.filter { $0.zone == nil }.count
    }

    func region(forID id: Int) -> Region? {
        regions[id]
    }

    // An offset's hour byte is at most 20 + 14, so the flag alone marks a region; the low two bits of byte 12 are not
    // part of the id.
    public static func regionID(wire bytes: [UInt8]) -> Int? {
        guard bytes.count >= 13, bytes[11] & regionFlag != 0 else { return nil }
        return (Int(bytes[11] & 0x7F) << 6) | (Int(bytes[12] & 0xFC) >> 2)
    }
}
