import Foundation

public struct DelimitedFileContents: Sendable {
    public let source: DelimitedSource
    public let undecodableLineCount: Int

    public var dialect: DelimitedDialect { source.dialect }
}

public enum DelimitedFileReader {
    private static let transcodingShare = 0.3

    public static func read(
        _ original: Data,
        fileExtension: String,
        dialectOverride: DelimitedDialect? = nil,
        transcodedFileURL: URL,
        progress: (@Sendable (Double) -> Void)? = nil,
        isCancelled: @escaping @Sendable () -> Bool = { false }
    ) async throws -> DelimitedFileContents {
        let sniff = TabularEncodingDetector.sniff(original)
        let encoding = dialectOverride?.encoding ?? sniff.encoding
        let byteOrderMarkLength = encoding == sniff.encoding ? sniff.byteOrderMarkLength : 0
        let text = try readText(
            original,
            encoding: encoding,
            byteOrderMarkLength: byteOrderMarkLength,
            transcodedFileURL: transcodedFileURL,
            progress: { progress?($0 * transcodingShare) },
            isCancelled: isCancelled
        )
        if isCancelled() { throw TabularCancellation() }
        let detected = text.bytes.withUnsafeBytes { raw in
            DelimitedDialectDetector.detect(
                raw.bindMemory(to: UInt8.self),
                contentStart: text.contentStart,
                encoding: encoding,
                hasByteOrderMark: byteOrderMarkLength > 0,
                fileExtension: fileExtension
            )
        }
        let buildStart = text.origin == nil ? 0 : transcodingShare
        let source = try await DelimitedSourceBuilder.build(
            bytes: text.bytes,
            dialect: dialectOverride ?? detected,
            byteEncoding: text.byteEncoding,
            contentStart: text.contentStart,
            origin: text.origin,
            progress: { progress?(buildStart + $0 * (0.95 - buildStart)) },
            isCancelled: isCancelled
        )
        return DelimitedFileContents(source: source, undecodableLineCount: text.undecodableLineCount)
    }

    private struct Text {
        let bytes: Data
        let byteEncoding: TabularTextEncoding
        let contentStart: Int
        let origin: TabularTranscodingMap?
        let undecodableLineCount: Int
    }

    private static func readText(
        _ original: Data,
        encoding: TabularTextEncoding,
        byteOrderMarkLength: Int,
        transcodedFileURL: URL,
        progress: (Double) -> Void,
        isCancelled: () -> Bool
    ) throws -> Text {
        guard !encoding.readsInPlace else {
            return Text(
                bytes: original,
                byteEncoding: encoding,
                contentStart: byteOrderMarkLength,
                origin: nil,
                undecodableLineCount: 0
            )
        }
        let transcoded = try TabularTextTranscoder.transcode(
            original,
            from: encoding,
            skippingPrefix: byteOrderMarkLength,
            to: transcodedFileURL,
            progress: progress,
            isCancelled: isCancelled
        )
        return Text(
            bytes: try Data(contentsOf: transcodedFileURL, options: .alwaysMapped),
            byteEncoding: .utf8,
            contentStart: 0,
            origin: transcoded.map,
            undecodableLineCount: transcoded.undecodableLineCount
        )
    }
}
