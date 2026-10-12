//
//  GeometryWKBParser.swift
//  MySQLDriverPlugin
//
//  Renders MySQL's internal geometry binary as EWKT.
//

import Foundation
import TableProGeometry

/// MySQL and MariaDB hand back a 4-byte little-endian SRID followed by ordinary WKB.
///
/// The reading is `TableProGeometry`'s, not this file's. It used to be a second hand-rolled WKB
/// parser, and two bugs came out of having two: a stored `GEOMETRYCOLLECTION EMPTY` rendered as the
/// invalid `GEOMETRYCOLLECTION()`, and a Z or M ordinate desynchronised the cursor because the body
/// assumed XY.
///
/// The SRID reaches the output. It used to be skipped, which left the app unable to tell 4326 from
/// 3857 from "nobody said" for a MySQL geometry column, so nothing downstream could decide whether
/// the coordinates were degrees.
///
/// The coordinate order is left exactly as stored. Measured byte-identical on MySQL 8.4.11 and
/// MariaDB 12.3.3, these bytes are longitude-first even for SRID 4326, whose `ST_AsText` prints
/// latitude first. Reordering them to match `ST_AsText` would move every MySQL point to the wrong
/// hemisphere.
nonisolated enum GeometryWKBParser {
    static func parse(_ data: Data) -> String {
        guard data.count >= 9 else { return hexString(data) }
        switch WKBGeometryReader.read(mysqlInternal: Array(data)) {
        case .success(let value):
            return WKTGeometryWriter.string(from: value)
        case .failure:
            return hexString(data)
        }
    }

    static func parse(_ buffer: UnsafeRawBufferPointer) -> String {
        parse(Data(buffer))
    }

    static func hexString(_ data: Data) -> String {
        if data.isEmpty { return "" }
        return "0x" + data.map { String(format: "%02X", $0) }.joined()
    }
}
