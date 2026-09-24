import CoreFoundation
import Foundation
@testable import TableProTabularIO
import XCTest

final class JSONDifferentialTests: XCTestCase {
    private struct SeededGenerator: RandomNumberGenerator {
        var state: UInt64

        mutating func next() -> UInt64 {
            state &+= 0x9E37_79B9_7F4A_7C15
            var value = state
            value = (value ^ (value >> 30)) &* 0xBF58_476D_1CE4_E5B9
            value = (value ^ (value >> 27)) &* 0x94D0_49BB_1331_11EB
            return value ^ (value >> 31)
        }
    }

    private struct DocumentGenerator {
        var random: SeededGenerator
        let allowsUnicodeEscapes: Bool
        let keys = ["id", "name", "a", "b", "c d", "x\\\"y", "{k}", ""]

        mutating func pick<T>(_ options: [T]) -> T {
            options[Int.random(in: 0..<options.count, using: &random)]
        }

        mutating func chance(_ percent: Int) -> Bool {
            Int.random(in: 0..<100, using: &random) < percent
        }

        mutating func whitespace(compact: Bool) -> String {
            compact ? "" : pick(["", "", " ", "\n  ", "\t", "\r\n    "])
        }

        mutating func string() -> String {
            var fragments = ["a", "b", " ", "\\\"", "\\\\", "\\n", "\\/", "{", "}", "[", "]", ":", ",", "x"]
            if allowsUnicodeEscapes {
                fragments += ["\\u00e9", "\\ud83d\\ude00", "é"]
            }
            let body = (0..<Int.random(in: 0...18, using: &random)).map { _ in pick(fragments) }.joined()
            return "\"\(body)\""
        }

        mutating func value(depth: Int, compact: Bool) -> String {
            let choice = Int.random(in: 0..<(depth < 3 ? 8 : 6), using: &random)
            switch choice {
            case 0, 1:
                return string()
            case 2:
                return pick(["0", "-1", "3.14", "1e5", "-0", "12345678901234567890", "2E-3", "10", "1.0"])
            case 3:
                return pick(["true", "false"])
            case 4, 5:
                return "null"
            case 6:
                let items = (0..<Int.random(in: 0...3, using: &random)).map { _ in
                    whitespace(compact: compact) + value(depth: depth + 1, compact: compact) + whitespace(compact: compact)
                }
                return "[" + items.joined(separator: ",") + "]"
            default:
                return object(depth: depth + 1, compact: compact)
            }
        }

        mutating func object(depth: Int, compact: Bool) -> String {
            let members = (0..<Int.random(in: 0...5, using: &random)).map { _ -> String in
                let key = "\"\(pick(keys))\""
                let separator = whitespace(compact: compact) + ":" + whitespace(compact: compact)
                return whitespace(compact: compact) + key + separator + value(depth: depth, compact: compact) + whitespace(compact: compact)
            }
            return "{" + members.joined(separator: ",") + "}"
        }

        mutating func document(array: Bool, compact: Bool) -> String {
            let rows = (0..<Int.random(in: 0...6, using: &random)).map { _ in object(depth: 0, compact: compact) }
            guard array else {
                let ending = pick(["\n", "\r\n"])
                let body = rows.map { $0 + (chance(20) ? ending + ending : ending) }.joined()
                return chance(30) && body.hasSuffix(ending) ? String(body.dropLast(ending.count)) : body
            }
            let separator = compact ? "," : pick([",\n  ", ", ", ","])
            let opening = compact ? "[" : "[\n  "
            let closing = compact ? "]" : pick(["\n]\n", "\n]", "]"])
            return opening + rows.joined(separator: separator) + closing
        }
    }

    private func displayed(_ literal: String) async throws -> TabularCell {
        let source = try await JSONFixtures.source("{\"k\":\(literal)}")
        return source.cell(row: 0, column: 0)
    }

    private func cellsByKey(of source: JSONSource) -> [[String: TabularCell]] {
        (0..<source.rowCount).map { row in
            var cells: [String: TabularCell] = [:]
            for (column, cell) in source.cells(row: row).enumerated() where cell.kind != .missing {
                cells[source.keys[column]] = cell
            }
            return cells
        }
    }

    func testGeneratedDocumentsReadRoundTripAndSurviveEdits() async throws {
        var generator = DocumentGenerator(random: SeededGenerator(state: 2_026), allowsUnicodeEscapes: true)
        for trial in 0..<400 {
            let array = generator.chance(50)
            let text = generator.document(array: array, compact: !array || generator.chance(30))
            let source = try await JSONFixtures.source(text, kind: array ? .json : .jsonLines)
            XCTAssertEqual(try JSONFixtures.written(source, rows: JSONFixtures.untouchedRows(of: source)), text, "trial \(trial)")

            var expected = cellsByKey(of: source)
            var output: [JSONOutputRow] = []
            var outputExpected: [[String: TabularCell]] = []
            for row in 0..<source.rowCount {
                if generator.chance(15) { continue }
                var edits: [JSONMemberEdit] = []
                var appended: [JSONNewMember] = []
                for key in source.keys where generator.chance(25) {
                    if generator.chance(30) {
                        edits.append(JSONMemberEdit(sourceKey: key, change: .remove))
                        expected[row][key] = nil
                        continue
                    }
                    let literal = generator.value(depth: 2, compact: true)
                    edits.append(JSONMemberEdit(sourceKey: key, change: .replace(with: literal)))
                    expected[row][key] = try await displayed(literal)
                }
                if generator.chance(20) {
                    let literal = generator.value(depth: 2, compact: true)
                    appended.append(JSONNewMember(key: "added", literal: literal))
                    expected[row]["added"] = try await displayed(literal)
                }
                output.append(edits.isEmpty && appended.isEmpty ? .source(row) : .edited(row, JSONObjectEdit(edits: edits, appended: appended)))
                outputExpected.append(expected[row])
                if generator.chance(15) {
                    let literal = generator.value(depth: 2, compact: true)
                    output.append(.new([JSONNewMember(key: "fresh", literal: literal), JSONNewMember(key: "id", literal: "7")]))
                    outputExpected.append(["fresh": try await displayed(literal), "id": TabularCell(kind: .number, text: "7")])
                }
            }
            let written = try JSONFixtures.written(source, rows: output)
            let reread = try await JSONFixtures.source(written, kind: array ? .json : .jsonLines)
            XCTAssertEqual(cellsByKey(of: reread), outputExpected, "trial \(trial): \(text.debugDescription) -> \(written.debugDescription)")
        }
    }

    func testMutatedDocumentsAgreeWithJSONSerialization() async throws {
        var generator = DocumentGenerator(random: SeededGenerator(state: 99), allowsUnicodeEscapes: false)
        let alphabet = Array("{}[]\"\\:,01-.eatn x".utf8)
        var accepted = 0
        for trial in 0..<3_000 {
            var bytes = Array(generator.document(array: true, compact: generator.chance(50)).utf8)
            let position = Int.random(in: 0...bytes.count, using: &generator.random)
            let replacement = alphabet[Int.random(in: 0..<alphabet.count, using: &generator.random)]
            switch Int.random(in: 0..<3, using: &generator.random) {
            case 0 where position < bytes.count:
                bytes.remove(at: position)
            case 1 where position < bytes.count:
                bytes[position] = replacement
            default:
                bytes.insert(replacement, at: position)
            }
            let reference = (try? JSONSerialization.jsonObject(with: Data(bytes))) as? [Any]
            let referenceRows = reference?.compactMap { $0 as? [String: Any] }
            let referenceAccepts = referenceRows != nil && referenceRows?.count == reference?.count
            let description = String(bytes: bytes, encoding: .utf8)?.debugDescription ?? "\(bytes)"
            let ours: JSONSource
            do {
                ours = try await JSONFixtures.source(bytes, kind: .json)
            } catch let error as JSONTableError where referenceAccepts {
                XCTAssertTrue(Self.isTrailingComma(in: bytes, closingAt: error.byteOffset), "trial \(trial): \(error) \(description)")
                continue
            } catch {
                XCTAssertFalse(referenceAccepts, "trial \(trial): \(error) \(description)")
                continue
            }
            XCTAssertTrue(referenceAccepts, "trial \(trial): \(description)")
            guard let referenceRows, referenceAccepts else { continue }
            accepted += 1
            XCTAssertEqual(ours.rowCount, referenceRows.count, "trial \(trial)")
            XCTAssertEqual(Set(ours.keys), Set(referenceRows.flatMap(\.keys)), "trial \(trial): \(description)")
            for (row, object) in referenceRows.enumerated() {
                let memberKeys = try ours.objectLayout(ofRow: row).members.map(\.key)
                let repeatedKeys = Set(memberKeys.filter { key in memberKeys.filter { $0 == key }.count > 1 })
                for (column, key) in ours.keys.enumerated() where !repeatedKeys.contains(key) {
                    let cell = ours.cell(row: row, column: column)
                    guard let value = object[key] else {
                        XCTAssertEqual(cell.kind, .missing, "trial \(trial) row \(row) key \(key)")
                        continue
                    }
                    XCTAssertTrue(Self.cell(cell, matches: value), "trial \(trial) row \(row) key \(key): \(cell) vs \(value)")
                }
            }
        }
        XCTAssertGreaterThan(accepted, 300)
    }

    private static func isTrailingComma(in bytes: [UInt8], closingAt offset: Int) -> Bool {
        guard offset < bytes.count, bytes[offset] == JSONByte.closeBrace || bytes[offset] == JSONByte.closeBracket else {
            return false
        }
        let previous = bytes[..<offset].lastIndex { !JSONByte.isWhitespace($0) }
        return previous.map { bytes[$0] == JSONByte.comma } ?? false
    }

    private static func cell(_ cell: TabularCell, matches value: Any) -> Bool {
        switch value {
        case let string as String:
            return cell.kind == .text && cell.text == string
        case let number as NSNumber where CFGetTypeID(number) == CFBooleanGetTypeID():
            return cell.kind == .boolean && cell.text == (number.boolValue ? "true" : "false")
        case let number as NSNumber:
            return cell.kind == .number && Double(cell.text) == number.doubleValue
        case is NSNull:
            return cell.kind == .null && cell.text == "null"
        case is [Any], is [String: Any]:
            let parsed = try? JSONSerialization.jsonObject(with: Data(cell.text.utf8), options: .fragmentsAllowed)
            let expectedKind: TabularCellKind = value is [Any] ? .array : .object
            return cell.kind == expectedKind && (parsed as AnyObject?)?.isEqual(value) == true
        default:
            return false
        }
    }
}
