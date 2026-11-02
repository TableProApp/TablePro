import Foundation
import TableProPluginKit
import Testing

struct ClickHouseTabSeparatedRowDecoderChunkingTests {
    private static func decode(_ chunks: [Data]) -> [[PluginCellValue]] {
        var decoder = ClickHouseTabSeparatedRowDecoder()
        var rows: [[PluginCellValue]] = []
        for chunk in chunks {
            rows.append(contentsOf: decoder.consume(chunk))
        }
        rows.append(contentsOf: decoder.finish())
        return rows
    }

    private static func chunks(of body: Data, size: Int) -> [Data] {
        stride(from: 0, to: body.count, by: size).map { body.subdata(in: $0..<min($0 + size, body.count)) }
    }

    // ClickHouse escapes a carriage return inside a value, so a raw one is a value byte and only the
    // line feed ends a row.
    private static let bodyLines: [String] = [
        "id\tlabel\tpayload\nUInt32\tString\tString\n",
        "1\talpha\tone\n",
        "2\tbe\\nta\ttwo\r\n",
        "\n",
        "3\tga\rmma\tthree\n",
        "4\tünïcødé\tfour"
    ]
    private static let body = Data(bodyLines.joined().utf8)

    private static let expectedRows: [[PluginCellValue]] = [
        [.text("1"), .text("alpha"), .text("one")],
        [.text("2"), .text("be\nta"), .text("two\r")],
        [.text("3"), .text("ga\rmma"), .text("three")],
        [.text("4"), .text("ünïcødé"), .text("four")]
    ]

    @Test("The unsplit body reads as its rows")
    func readsTheUnsplitBody() {
        #expect(Self.decode([Self.body]) == Self.expectedRows)
    }

    @Test("A split at any byte, inside a CRLF or a character included, gives the same rows")
    func everySplitPointGivesTheSameRows() {
        for split in 0...Self.body.count {
            let rows = Self.decode([Self.body.subdata(in: 0..<split), Self.body.subdata(in: split..<Self.body.count)])
            #expect(rows == Self.expectedRows, "split at \(split)")
        }
    }

    @Test("Chunks of every small size give the same rows", arguments: 1...16)
    func everyChunkSizeGivesTheSameRows(size: Int) {
        #expect(Self.decode(Self.chunks(of: Self.body, size: size)) == Self.expectedRows)
    }

    @Test("A decoder that finished starts the next body clean")
    func finishResetsTheSearch() {
        var decoder = ClickHouseTabSeparatedRowDecoder()
        _ = decoder.consume(Data("id\nUInt32\n12345".utf8))
        #expect(decoder.finish() == [[.text("12345")]])
        #expect(decoder.consume(Data("6\n7\n".utf8)) == [[.text("6")], [.text("7")]])
    }

    // Rescanning the unfinished line on every chunk makes thousands of passes over megabytes here.
    // Resuming where the last search stopped reads each byte once, well inside the limit.
    @Test("A long value arriving in many small chunks is scanned once")
    func longLineInSmallChunksStaysLinear() {
        let valueLength = 2 << 20
        var body = Data("id\tpayload\nUInt32\tString\n1\t".utf8)
        body.append(Data(repeating: 0x78, count: valueLength))
        body.append(Data("\n".utf8))
        let chunks = Self.chunks(of: body, size: 512)

        var decoder = ClickHouseTabSeparatedRowDecoder()
        var rows: [[PluginCellValue]] = []
        let clock = ContinuousClock()
        let deadline = clock.now + .seconds(2)
        for chunk in chunks where clock.now < deadline {
            rows.append(contentsOf: decoder.consume(chunk))
        }
        rows.append(contentsOf: decoder.finish())

        #expect(clock.now < deadline, "decoding one long line in small chunks did not stay linear")
        #expect(rows.count == 1)
        guard case .text(let value) = rows.first?.last else {
            Issue.record("the long value did not decode as text")
            return
        }
        #expect(value.utf8.count == valueLength)
    }
}
