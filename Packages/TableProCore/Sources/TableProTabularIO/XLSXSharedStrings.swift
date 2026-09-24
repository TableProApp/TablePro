import Foundation

public struct XLSXSharedStrings: Sendable {
    let heap: XLSXByteHeap
    let handles: XLSXChunkedArray<UInt64>

    public static let empty = XLSXSharedStrings(heap: .empty, handles: XLSXChunkedArray())

    init(heap: XLSXByteHeap, handles: XLSXChunkedArray<UInt64>) {
        self.heap = heap
        self.handles = handles
    }

    public var count: Int { handles.count }

    public func string(at index: Int) -> String? {
        guard let bytes = bytes(at: index) else { return nil }
        return TabularTextCodec.string(from: bytes, encoding: .utf8)
    }

    func bytes(at index: Int) -> UnsafeBufferPointer<UInt8>? {
        guard index >= 0, index < count else { return nil }
        return heap.bytes(at: handles[index])
    }
}

struct XLSXSharedStringsReader {
    private let heap = XLSXByteHeapBuilder()
    private var handles = XLSXChunkedArray<UInt64>()
    private var scratch: [UInt8] = []

    static func read(
        _ archive: ZipArchive,
        entry: ZipArchive.Entry,
        chunkSize: Int,
        progress: ((Double) -> Void)?,
        isCancelled: () -> Bool
    ) throws -> XLSXSharedStrings {
        var reader = XLSXSharedStringsReader()
        try XLSXStreamingParse.run(
            archive,
            entry: entry,
            chunkSize: chunkSize,
            progress: progress,
            isCancelled: isCancelled
        ) { buffer, isFinal in
            reader.consume(buffer, isFinal: isFinal)
        }
        return XLSXSharedStrings(heap: reader.heap.finish(), handles: reader.handles)
    }

    mutating func consume(_ buffer: UnsafeBufferPointer<UInt8>, isFinal: Bool) -> Int {
        var scanner = XMLByteScanner(bytes: buffer, isFinal: isFinal)
        while true {
            let mark = scanner.position
            switch scanner.next() {
            case .startTag(let name, _, let isSelfClosing):
                guard scanner.isNamed(name, "si") else { continue }
                scratch.removeAll(keepingCapacity: true)
                guard isSelfClosing || XLSXRichText.read(&scanner, closing: "si", into: &scratch) else {
                    return mark
                }
                let text = scratch
                handles.append(text.withUnsafeBufferPointer { heap.append($0) })
            case .incomplete:
                return mark
            case .end:
                return scanner.position
            case .endTag, .text, .characterData, .markup:
                continue
            }
        }
    }
}

enum XLSXRichText {
    static func read(
        _ scanner: inout XMLByteScanner,
        closing element: StaticString,
        into output: inout [UInt8]
    ) -> Bool {
        while true {
            switch scanner.next() {
            case .startTag(let name, _, let isSelfClosing):
                if isSelfClosing { continue }
                if scanner.isNamed(name, "t") {
                    guard appendText(&scanner, into: &output) else { return false }
                } else if scanner.isNamed(name, "rPh") || scanner.isNamed(name, "rPr") || scanner.isNamed(name, "phoneticPr") {
                    guard scanner.skipElement(named: name) else { return false }
                }
            case .endTag(let name):
                if scanner.isNamed(name, element) { return true }
            case .text, .characterData, .markup:
                continue
            case .incomplete, .end:
                return false
            }
        }
    }

    static func appendText(_ scanner: inout XMLByteScanner, into output: inout [UInt8]) -> Bool {
        while true {
            switch scanner.next() {
            case .text(let range):
                XMLTextDecoder.append(scanner.bytes, range, to: &output, unescapingOOXML: true)
            case .characterData(let range):
                output.append(contentsOf: UnsafeBufferPointer(rebasing: scanner.bytes[range]))
            case .endTag:
                return true
            case .startTag(let name, _, let isSelfClosing):
                if !isSelfClosing, !scanner.skipElement(named: name) { return false }
            case .markup:
                continue
            case .incomplete, .end:
                return false
            }
        }
    }
}
