//
//  JSONDocumentOutline.swift
//  JSONImportPlugin
//

import Foundation
import TableProPluginKit

enum JSONDocumentRows: Equatable {
    // The rows are the elements of the array that opens at `offset`. `slot` is the one `visit` was given for them.
    case array(offset: Int, elementCount: Int, slot: Int)
    // A single object, which is one row, or text in UTF-16 or UTF-32: `JSONSerialization` reads the file whole.
    case wholeDocument
}

// Finds which array of a `.json` file holds the rows, by the rules `JSONImportParsing.extractElements`
// applies to a parsed file, in one pass that builds nothing but member names.
enum JSONDocumentOutline {
    private struct Member {
        let name: String
        let slot: Int
        let offset: Int
        let elementCount: Int
        let holdsRows: Bool
    }

    // `visit` gets the reader at each array element and at each member value that is not an array,
    // and moves it past that value. `slot` is 0 for the elements of a top-level array, the member's
    // position for the elements of a member's array, and nil for a value that cannot become a row.
    static func rows(
        in reader: inout JSONDocumentReader,
        targetTable: String?,
        visit: (inout JSONDocumentReader, _ slot: Int?) throws -> Void
    ) throws -> JSONDocumentRows {
        guard try reader.startDocument() else { return .wholeDocument }
        guard let first = try reader.nextSignificantByte() else { throw JSONDocumentError.endsEarly }
        switch first {
        case JSONDocumentReader.openBracket:
            let offset = reader.offset
            let array = try elements(of: &reader, slot: 0, visit: visit)
            try reader.expectEnd()
            return .array(offset: offset, elementCount: array.count, slot: 0)
        case JSONDocumentReader.openBrace:
            return try memberRows(in: &reader, targetTable: targetTable, visit: visit)
        case 0x22, 0x2D, 0x30...0x39, 0x66, 0x6E, 0x74:
            throw JSONImportParsing.unexpectedShapeError
        default:
            throw JSONDocumentError.unexpectedCharacter(byteOffset: reader.offset)
        }
    }

    private static func elements(
        of reader: inout JSONDocumentReader,
        slot: Int?,
        visit: (inout JSONDocumentReader, _ slot: Int?) throws -> Void
    ) throws -> (count: Int, allObjects: Bool) {
        guard try reader.enterArray() else { return (0, true) }
        var count = 0
        var allObjects = true
        repeat {
            if try reader.nextSignificantByte() != JSONDocumentReader.openBrace {
                allObjects = false
            }
            try visit(&reader, slot)
            count += 1
        } while try reader.continueArray()
        return (count, allObjects)
    }

    private static func memberRows(
        in reader: inout JSONDocumentReader,
        targetTable: String?,
        visit: (inout JSONDocumentReader, _ slot: Int?) throws -> Void
    ) throws -> JSONDocumentRows {
        var members: [Member] = []
        var names: Set<String> = []
        if try reader.enterObject() {
            repeat {
                let name = try reader.memberName()
                // A parsed object keeps the first of two members that share a name.
                let slot = names.insert(name).inserted ? members.count : nil
                let offset = reader.offset
                var array = (count: 0, allObjects: false)
                if try reader.nextSignificantByte() == JSONDocumentReader.openBracket {
                    array = try elements(of: &reader, slot: slot, visit: visit)
                } else {
                    try visit(&reader, nil)
                }
                if let slot {
                    members.append(Member(
                        name: name, slot: slot, offset: offset,
                        elementCount: array.count, holdsRows: array.allObjects
                    ))
                }
            } while try reader.continueObject()
        }
        try reader.expectEnd()

        guard !members.isEmpty, members.allSatisfy({ $0.holdsRows }) else { return .wholeDocument }
        let match = targetTable.flatMap { target in
            members.first { $0.name.caseInsensitiveCompare(target) == .orderedSame }
                ?? members.first { $0.name.split(separator: ".").last?.caseInsensitiveCompare(target) == .orderedSame }
        }
        guard let table = match ?? (members.count == 1 ? members[0] : nil) else {
            throw JSONImportParsing.noMatchingTableError
        }
        return .array(offset: table.offset, elementCount: table.elementCount, slot: table.slot)
    }
}
