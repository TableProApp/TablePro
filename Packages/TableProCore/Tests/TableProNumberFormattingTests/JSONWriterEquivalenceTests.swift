import XCTest
@testable import TableProNumberFormatting

private struct Seeded: RandomNumberGenerator {
    private var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}

final class JSONWriterEquivalenceTests: XCTestCase {
    private let alphabet: [String] = [
        "", "a", "a/b", "q\"x", "back\\slash", "tab\there", "nl\nhere", "cr\rhere",
        "\u{08}\u{0C}", "\u{01}\u{1F}", "café → 日本", "\u{7F}", "emoji 🎉", "key.with.dots",
    ]

    private func randomLeaf(_ g: inout Seeded) -> Any {
        switch Int.random(in: 0 ..< 6, using: &g) {
        case 0: return NSNull()
        case 1: return alphabet[Int.random(in: 0 ..< alphabet.count, using: &g)]
        case 2: return Bool.random(using: &g)
        case 3: return Int64.random(in: -1_000_000 ... 1_000_000, using: &g)
        case 4:
            var d = Double(bitPattern: UInt64.random(in: 0 ... UInt64.max, using: &g))
            if !d.isFinite { d = 1847.27 }
            return d
        default: return Double(Int.random(in: -1000 ... 1000, using: &g))
        }
    }

    private func randomValue(_ g: inout Seeded, depth: Int) -> Any {
        guard depth < 3, Int.random(in: 0 ..< 3, using: &g) > 0 else { return randomLeaf(&g) }
        if Bool.random(using: &g) {
            return (0 ..< Int.random(in: 0 ... 4, using: &g)).map { _ in randomValue(&g, depth: depth + 1) }
        }
        var dict: [String: Any] = [:]
        for _ in 0 ..< Int.random(in: 0 ... 4, using: &g) {
            dict[alphabet[Int.random(in: 0 ..< alphabet.count, using: &g)]] = randomValue(&g, depth: depth + 1)
        }
        return dict
    }

    /// The writer replaced JSONEncoder to control number spelling. Everything else it emits,
    /// especially string escaping, must stay byte for byte what the platform encoder produced,
    /// with one deliberate exception: escaping `/` is optional in JSON and the writer does not do
    /// it, so the reference encoder is asked not to either. A path, URL or MQTT topic reads and
    /// copies as it was stored instead of arriving as `device\/state\/up`.
    func testWriterMatchesJSONEncoderByteForByte() throws {
        var g = Seeded(seed: 0x5EED_1501_0000_0001)
        var compared = 0
        for _ in 0 ..< 4000 {
            let value = randomValue(&g, depth: 0)
            guard let mine = NumberText.json(from: value) else { continue }
            guard let reference = referenceJSON(value) else { continue }
            compared += 1
            XCTAssertEqual(mine, reference, "diverged for \(value)")
        }
        XCTAssertGreaterThan(compared, 1000)
    }

    private func referenceJSON(_ value: Any) -> String? {
        guard let node = ReferenceNode(value) else { return nil }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        guard let data = try? encoder.encode(node) else { return nil }
        return String(data: data, encoding: .utf8)
    }
}

private enum ReferenceNode: Encodable {
    case null, bool(Bool), string(String), double(Double), integer(Int64)
    case array([ReferenceNode]), object([String: ReferenceNode])

    init?(_ value: Any) {
        switch value {
        case is NSNull: self = .null
        case let s as String: self = .string(s)
        case let b as Bool: self = .bool(b)
        case let i as Int64: self = .integer(i)
        case let d as Double: self = .double(d)
        case let a as [Any]:
            var nodes: [ReferenceNode] = []
            for e in a { guard let n = ReferenceNode(e) else { return nil }; nodes.append(n) }
            self = .array(nodes)
        case let d as [String: Any]:
            var nodes: [String: ReferenceNode] = [:]
            for (k, v) in d { guard let n = ReferenceNode(v) else { return nil }; nodes[k] = n }
            self = .object(nodes)
        default: return nil
        }
    }

    func encode(to encoder: any Encoder) throws {
        switch self {
        case .array(let values):
            var c = encoder.unkeyedContainer()
            for v in values { try c.encode(v) }
        case .object(let values):
            var c = encoder.container(keyedBy: Key.self)
            for (k, v) in values { try c.encode(v, forKey: Key(k)) }
        case .null:
            var c = encoder.singleValueContainer(); try c.encodeNil()
        case .bool(let v):
            var c = encoder.singleValueContainer(); try c.encode(v)
        case .string(let v):
            var c = encoder.singleValueContainer(); try c.encode(v)
        case .double(let v):
            var c = encoder.singleValueContainer(); try c.encode(v)
        case .integer(let v):
            var c = encoder.singleValueContainer(); try c.encode(v)
        }
    }

    private struct Key: CodingKey {
        let stringValue: String
        let intValue: Int? = nil
        init(_ s: String) { stringValue = s }
        init?(stringValue: String) { self.stringValue = stringValue }
        init?(intValue: Int) { return nil }
    }
}
