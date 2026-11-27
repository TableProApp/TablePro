import Foundation
import os
import TableProPluginKit

/// Intervals for the stages of a read, so Instruments shows where a page's time goes: the shell, the cursor, the
/// decode and the grid build.
nonisolated enum MongoReadTrace {
    static let signposter = OSSignposter(subsystem: "com.TablePro", category: "MongoDBRead")
}

/// A stored document read once: its values as the grid and the kind caches take them, its canonical Extended JSON
/// tree in stored field order, the locator of its `_id`, and its stored size.
nonisolated struct MongoReadDocument {
    let dictionary: [String: Any]
    /// Nil when the strict reader would refuse the document's text, as it does a field name repeated in one
    /// document or a document nested past `MongoDocumentText.maximumDepth`.
    let canonical: MongoDocumentText?
    /// The compact canonical Extended JSON of the first `_id`, or nil when the document has none.
    let identifier: String?
    let bsonSize: Int?

    /// A document that only exists as Extended JSON, which is what a script builds and hands back.
    init?(canonicalJSON text: String) {
        guard let data = text.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data),
              let dictionary = object as? [String: Any] else { return nil }
        #if canImport(CLibMongoc)
        self.dictionary = MongoDBConnection.unwrapExtendedJson(dictionary) as? [String: Any] ?? dictionary
        bsonSize = MongoLibbsonCodec().bsonSize(of: text)
        #else
        self.dictionary = dictionary
        bsonSize = nil
        #endif
        if case .object(let members) = try? MongoDocumentText.Value(parsing: text) {
            canonical = MongoDocumentText(members: members)
        } else {
            canonical = nil
        }
        identifier = MongoDocumentIdentity.locator(inDocument: text)
    }

    init(dictionary: [String: Any], canonical: MongoDocumentText?, identifier: String?, bsonSize: Int?) {
        self.dictionary = dictionary
        self.canonical = canonical
        self.identifier = identifier
        self.bsonSize = bsonSize
    }
}

#if canImport(CLibMongoc)
import CLibMongoc

/// Reads stored BSON with libbson's iterator, one pass a document.
///
/// The pass yields the same Swift values `MongoDBConnection.unwrapExtendedJson` makes from canonical Extended JSON
/// and the same tree `MongoDocumentText` reads from that text, so nothing downstream can tell the two apart. The
/// common types are written here; the rare ones (regular expressions, code, symbols, timestamps, DBPointers, MinKey,
/// MaxKey, undefined) go through libbson's own Extended JSON for that one value, so their spelling stays libbson's.
nonisolated final class MongoBsonDocumentReader {
    // libbson declares bson_iter_t 128-byte aligned, which Swift cannot stack-allocate, so each nesting depth keeps
    // one aligned iterator for the reader's life.
    private var iterators: [UnsafeMutableRawPointer] = []
    private let buildsCanonical: Bool

    private static let iteratorBytes = 128
    private static let iteratorAlignment = 128

    /// Without the canonical tree, for a reply or a sample whose values are all a caller reads.
    init(buildsCanonical: Bool = true) {
        self.buildsCanonical = buildsCanonical
    }

    deinit {
        iterators.forEach { $0.deallocate() }
    }

    func read(_ bson: OpaquePointer) -> MongoReadDocument? {
        guard let data = bson_get_data(bson) else { return nil }
        return read(data: data, length: Int(MongoLibbsonCodec.size(of: bson)))
    }

    func read(_ stored: Data) -> MongoReadDocument? {
        stored.withUnsafeBytes { raw in
            guard let base = raw.baseAddress?.assumingMemoryBound(to: UInt8.self) else { return nil }
            return read(data: base, length: raw.count)
        }
    }

    func read(data: UnsafePointer<UInt8>, length: Int) -> MongoReadDocument? {
        let iterator = iterator(atDepth: 0)
        guard length >= 5, bson_iter_init_from_data(iterator, data, length) else { return nil }
        var state = State()
        guard case .document(let dictionary, let members)? = readDocument(iterator, depth: 1, state: &state) else {
            return nil
        }
        let canonical = buildsCanonical && state.isStrict ? members.map(MongoDocumentText.init(members:)) : nil
        return MongoReadDocument(
            dictionary: dictionary, canonical: canonical, identifier: state.identifier, bsonSize: length
        )
    }

    private struct State {
        var isStrict = true
        var identifier: String?
        var readsIdentifier = false
    }

    // The canonical parts are nil once a value inside has none: a partial `_id` would name another document.
    private enum Container {
        case document([String: Any], [MongoDocumentText.Member]?)
        case array([Any], [MongoDocumentText.Value]?)
    }

    private func iterator(atDepth depth: Int) -> OpaquePointer {
        while iterators.count <= depth {
            let pointer = UnsafeMutableRawPointer.allocate(
                byteCount: Self.iteratorBytes, alignment: Self.iteratorAlignment
            )
            pointer.initializeMemory(as: UInt8.self, repeating: 0, count: Self.iteratorBytes)
            iterators.append(pointer)
        }
        return OpaquePointer(iterators[depth])
    }

    private func readDocument(_ iterator: OpaquePointer, depth: Int, state: inout State) -> Container? {
        if depth > MongoDocumentText.maximumDepth { state.isStrict = false }
        var dictionary: [String: Any] = [:]
        var members: [MongoDocumentText.Member] = []
        var isComplete = true
        while bson_iter_next(iterator) {
            guard let keyPointer = bson_iter_key(iterator) else { return nil }
            let key = String(cString: keyPointer)
            guard let value = readValue(iterator, depth: depth, state: &state) else { return nil }
            if buildsCanonical {
                // A strict read refuses a repeated name, so the document then has no canonical tree, as before. Names
                // are compared as bytes, since Swift calls two spellings of one character equal and BSON does not.
                if dictionary[key] != nil, members.contains(where: { $0.key.utf8.elementsEqual(key.utf8) }) {
                    state.isStrict = false
                }
                if depth == 1, key == MongoDocumentIdentity.field, !state.readsIdentifier {
                    state.readsIdentifier = true
                    state.identifier = value.canonical?.compactText
                }
                if let canonical = value.canonical {
                    members.append(MongoDocumentText.Member(key: key, value: canonical))
                } else {
                    state.isStrict = false
                    isComplete = false
                }
            }
            dictionary[key] = value.decoded
        }
        guard Self.reachedEnd(iterator) else { return nil }
        return .document(dictionary, isComplete ? members : nil)
    }

    private func readArray(_ iterator: OpaquePointer, depth: Int, state: inout State) -> Container? {
        if depth > MongoDocumentText.maximumDepth { state.isStrict = false }
        var decoded: [Any] = []
        var canonical: [MongoDocumentText.Value] = []
        var isComplete = true
        while bson_iter_next(iterator) {
            guard let value = readValue(iterator, depth: depth, state: &state) else { return nil }
            decoded.append(value.decoded)
            if buildsCanonical {
                if let value = value.canonical {
                    canonical.append(value)
                } else {
                    state.isStrict = false
                    isComplete = false
                }
            }
        }
        guard Self.reachedEnd(iterator) else { return nil }
        return .array(decoded, isComplete ? canonical : nil)
    }

    // libbson stops at a corrupt element and records where; a clean end leaves no error offset.
    private static func reachedEnd(_ iterator: OpaquePointer) -> Bool {
        UnsafeRawPointer(iterator).assumingMemoryBound(to: bson_iter_t.self).pointee.err_off == 0
    }

    private struct Value {
        let decoded: Any
        // Nil when the strict reader refuses the value's own text, which leaves its document no canonical tree.
        let canonical: MongoDocumentText.Value?
    }

    private func readValue(_ iterator: OpaquePointer, depth: Int, state: inout State) -> Value? {
        switch bson_iter_type(iterator) {
        case BSON_TYPE_DOUBLE:
            let value = bson_iter_double(iterator)
            return Value(decoded: value, canonical: wrapped("$numberDouble", .string(Self.canonicalText(of: value))))
        case BSON_TYPE_UTF8:
            guard let text = Self.utf8(iterator) else { return nil }
            return Value(decoded: text, canonical: .string(text))
        case BSON_TYPE_DOCUMENT, BSON_TYPE_ARRAY:
            let isArray = bson_iter_type(iterator) == BSON_TYPE_ARRAY
            let child = self.iterator(atDepth: depth)
            guard bson_iter_recurse(iterator, child) else { return nil }
            let container = isArray
                ? readArray(child, depth: depth + 1, state: &state)
                : readDocument(child, depth: depth + 1, state: &state)
            switch container {
            case .document(let dictionary, let members)?:
                return Value(decoded: dictionary, canonical: members.map { .object($0) })
            case .array(let values, let canonical)?:
                return Value(decoded: values, canonical: canonical.map { .array($0) })
            case nil:
                return nil
            }
        case BSON_TYPE_BINARY:
            var subtype = BSON_SUBTYPE_BINARY
            var length: UInt32 = 0
            var bytes: UnsafePointer<UInt8>?
            bson_iter_binary(iterator, &subtype, &length, &bytes)
            let data = bytes.map { Data(bytes: $0, count: Int(length)) } ?? Data()
            let code = UInt8(truncatingIfNeeded: subtype.rawValue)
            let canonical = wrapped("$binary", .object([
                MongoDocumentText.Member(key: "base64", value: .string(data.base64EncodedString())),
                MongoDocumentText.Member(key: "subType", value: .string(Self.hexByte(code))),
            ]))
            return Value(decoded: MongoDBBinaryValue(data: data, subtype: code), canonical: canonical)
        case BSON_TYPE_OID:
            guard let oid = bson_iter_oid(iterator) else { return nil }
            let hex = Self.hex(of: oid)
            return Value(decoded: MongoDBObjectId(hex: hex), canonical: wrapped("$oid", .string(hex)))
        case BSON_TYPE_BOOL:
            let value = bson_iter_bool(iterator)
            return Value(decoded: NSNumber(value: value), canonical: .literal(value ? "true" : "false"))
        case BSON_TYPE_DATE_TIME:
            let milliseconds = bson_iter_date_time(iterator)
            return Value(
                decoded: Date(timeIntervalSince1970: Double(milliseconds) / 1_000.0),
                canonical: wrapped("$date", wrapped("$numberLong", .string(String(milliseconds))))
            )
        case BSON_TYPE_NULL:
            return Value(decoded: NSNull(), canonical: .literal("null"))
        case BSON_TYPE_INT32:
            let value = bson_iter_int32(iterator)
            return Value(decoded: value, canonical: wrapped("$numberInt", .string(String(value))))
        case BSON_TYPE_INT64:
            let value = bson_iter_int64(iterator)
            return Value(decoded: value, canonical: wrapped("$numberLong", .string(String(value))))
        case BSON_TYPE_DECIMAL128:
            guard let digits = Self.decimalText(iterator) else { return nil }
            return Value(decoded: MongoDBDecimal128(digits: digits), canonical: wrapped("$numberDecimal", .string(digits)))
        default:
            return Self.libbsonValue(iterator)
        }
    }

    private func wrapped(_ key: String, _ value: MongoDocumentText.Value) -> MongoDocumentText.Value {
        .object([MongoDocumentText.Member(key: key, value: value)])
    }

    // Invalid UTF-8 has no Extended JSON, which libbson answers by refusing the whole document.
    private static func utf8(_ iterator: OpaquePointer) -> String? {
        var length: UInt32 = 0
        guard let pointer = bson_iter_utf8(iterator, &length) else { return nil }
        let bytes = UnsafeRawBufferPointer(start: pointer, count: Int(length))
        let buffer = bytes.bindMemory(to: UInt8.self)
        // Decoded, then compared byte for byte: a repaired decode differs, so only valid UTF-8 comes back.
        let text = String(decoding: buffer, as: UTF8.self) // swiftlint:disable:this optional_data_string_conversion
        return text.utf8.elementsEqual(buffer) ? text : nil
    }

    /// libbson's canonical spelling: `%.20g`, with `.0` added to a value that reads as an integer.
    static func canonicalText(of value: Double) -> String {
        if value.isNaN { return "NaN" }
        if value.isInfinite { return value > 0 ? "Infinity" : "-Infinity" }
        return withUnsafeTemporaryAllocation(of: CChar.self, capacity: 64) { buffer in
            guard let base = buffer.baseAddress else { return String(value) }
            let written = withVaList([value]) { vsnprintf(base, buffer.count, "%.20g", $0) }
            let text = String(cString: base)
            guard written > 0, text.utf8.allSatisfy({ $0 == UInt8(ascii: "-") || (0x30...0x39).contains($0) }) else {
                return text
            }
            return text + ".0"
        }
    }

    private static let hexDigits = Array("0123456789abcdef".utf8)

    private static func hexByte(_ byte: UInt8) -> String {
        // Hex digits are ASCII, so the decode never repairs anything.
        String(decoding: [hexDigits[Int(byte >> 4)], hexDigits[Int(byte & 0x0F)]], as: UTF8.self) // swiftlint:disable:this optional_data_string_conversion
    }

    private static func hex(of oid: UnsafePointer<bson_oid_t>) -> String {
        withUnsafeBytes(of: oid.pointee.bytes) { raw in
            var digits: [UInt8] = []
            digits.reserveCapacity(24)
            for byte in raw {
                digits.append(hexDigits[Int(byte >> 4)])
                digits.append(hexDigits[Int(byte & 0x0F)])
            }
            return String(decoding: digits, as: UTF8.self) // swiftlint:disable:this optional_data_string_conversion
        }
    }

    private static func decimalText(_ iterator: OpaquePointer) -> String? {
        var decimal = bson_decimal128_t()
        guard bson_iter_decimal128(iterator, &decimal) else { return nil }
        return withUnsafeTemporaryAllocation(of: CChar.self, capacity: Int(BSON_DECIMAL128_STRING)) { buffer in
            guard let base = buffer.baseAddress else { return nil }
            bson_decimal128_to_string(&decimal, base)
            return String(cString: base)
        }
    }

    /// The value as libbson spells it in canonical Extended JSON, decoded as that text always was.
    private static func libbsonValue(_ iterator: OpaquePointer) -> Value? {
        let single = bson_new()
        defer { bson_destroy(single) }
        guard bson_append_iter(single, "v", 1, iterator) else { return nil }
        var length = 0
        guard let json = bson_as_canonical_extended_json(single, &length) else { return nil }
        defer { bson_free(json) }
        let text = String(cString: json)
        guard let data = text.data(using: .utf8),
              let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let raw = object["v"] else { return nil }
        // A code scope can repeat a name, which the strict reader refuses; the row still reads, as it did from text.
        let parsed = try? MongoDocumentText.Value(parsing: text)
        guard case .object(let members)? = parsed, let member = members.first else {
            return Value(decoded: MongoDBConnection.unwrapExtendedJson(raw), canonical: nil)
        }
        return Value(decoded: MongoDBConnection.unwrapExtendedJson(raw), canonical: member.value)
    }
}
#endif
