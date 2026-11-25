//
//  CloudKitRecordConversion.swift
//  TablePro
//

import CloudKit
import Foundation
import os
import TableProFFI
import TableProSyncTransport

// CloudKit's records and values as the core engine takes them (core ADR 0054, The CloudKit transport): field values in
// CloudKit's own types, and the system fields as `encodeSystemFields(with:)` writes them, which a save rebuilds the
// record from so its change tag still guards it.
nonisolated enum CloudKitRecordConversion {
    private static let logger = Logger(subsystem: "com.TablePro", category: "CloudKitRecordConversion")

    // CloudKit's rule for record type and field names: an ASCII letter, then letters, digits and underscores, at most
    // 255 in all. `CKRecord` raises on a name outside it instead of failing.
    static func isValidName(_ name: String) -> Bool {
        let scalars = Array(name.unicodeScalars)
        guard let first = scalars.first, scalars.count <= 255, isLetter(first) else { return false }
        return scalars.allSatisfy { isLetter($0) || ("0"..."9").contains($0) || $0 == "_" }
    }

    private static func isLetter(_ scalar: Unicode.Scalar) -> Bool {
        ("a"..."z").contains(scalar) || ("A"..."Z").contains(scalar)
    }

    // MARK: - From CloudKit

    static func record(_ record: CKRecord) -> CloudKitRecord {
        var fields: [CloudKitField] = []
        for key in record.allKeys().sorted() {
            guard let converted = value(record[key]) else {
                // Only CloudKit's own fields carry other types; a save never resends a field it does not name.
                logger.debug("Left out a field of a type the core does not carry")
                continue
            }
            fields.append(CloudKitField(name: key, value: converted))
        }
        return CloudKitRecord(
            recordType: record.recordType,
            name: record.recordID.recordName,
            systemFields: systemFields(of: record),
            fields: fields
        )
    }

    static func systemFields(of record: CKRecord) -> Data {
        let coder = NSKeyedArchiver(requiringSecureCoding: true)
        record.encodeSystemFields(with: coder)
        coder.finishEncoding()
        return coder.encodedData
    }

    static func value(_ value: Any?) -> CloudKitValue? {
        switch value {
        case let text as String:
            return .text(value: text)
        case let date as Date:
            return .timestamp(value: milliseconds(date))
        case let data as Data:
            return .bytes(value: data)
        case let number as NSNumber:
            return CFNumberIsFloatType(number as CFNumber) ? .double(value: number.doubleValue) : .int64(value: number.int64Value)
        case let list as [String]:
            return .textList(value: list)
        default:
            return nil
        }
    }

    static func milliseconds(_ date: Date) -> Int64 {
        Int64((date.timeIntervalSince1970 * 1_000).rounded())
    }

    // MARK: - To CloudKit

    enum Refusal: Error, Equatable {
        // A name, type or system fields CloudKit would raise on, or that names another record.
        case invalid
    }

    // A save carries system fields unless it creates the record, in `zone`, the zone the call is bound to.
    static func ckRecord(_ record: CloudKitRecord, in zone: CKRecordZone.ID) throws(Refusal) -> CKRecord {
        guard isValidName(record.recordType), record.fields.allSatisfy({ isValidName($0.name) }) else {
            throw .invalid
        }
        let built: CKRecord
        if let systemFields = record.systemFields {
            guard let rebuilt = rebuild(systemFields),
                  rebuilt.recordType == record.recordType,
                  rebuilt.recordID.recordName == record.name,
                  rebuilt.recordID.zoneID.zoneName == zone.zoneName
            else { throw .invalid }
            built = rebuilt
        } else {
            guard let id = CloudKitRecordID.make(name: record.name, in: zone) else { throw .invalid }
            built = CKRecord(recordType: record.recordType, recordID: id)
        }
        for field in record.fields {
            built[field.name] = field.value.map(ckValue)
        }
        return built
    }

    static func rebuild(_ systemFields: Data) -> CKRecord? {
        guard let coder = try? NSKeyedUnarchiver(forReadingFrom: systemFields) else { return nil }
        coder.requiresSecureCoding = true
        defer { coder.finishDecoding() }
        return CKRecord(coder: coder)
    }

    static func ckValue(_ value: CloudKitValue) -> any CKRecordValueProtocol {
        switch value {
        case .text(let text):
            return text
        case .int64(let number):
            return number
        case .double(let number):
            return number
        case .timestamp(let milliseconds):
            return Date(timeIntervalSince1970: Double(milliseconds) / 1_000)
        case .bytes(let data):
            return data
        case .textList(let list):
            return list
        }
    }
}
