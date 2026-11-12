//
//  LineFoldCalculator.swift
//  TableProEditorKit
//
//  Created by Khan Winter on 5/9/25.
//

import AppKit
import TableProTextEngine

// Each pass carries the document version it read, so the model can drop a result for text that has since changed.
struct LineFoldPass: Sendable {
    let storage: LineFoldStorage
    let documentVersion: Int
}

@MainActor
final class LineFoldDocumentVersion {
    private(set) var value = 0

    func advance() {
        value &+= 1
    }
}

actor LineFoldCalculator {
    weak var foldProvider: LineFoldProvider?
    weak var controller: TextViewController?

    var valueStream: AsyncStream<LineFoldPass>

    private var valueStreamContinuation: AsyncStream<LineFoldPass>.Continuation
    private var textChangedTask: Task<Void, Never>?
    private let documentVersion: LineFoldDocumentVersion

    private struct PassStart: Sendable {
        let documentRange: NSRange
        let sizeLimit: Int
        let documentVersion: Int
        let scanner: LineFoldDocumentScanner?
        let text: String?
    }

    init(
        foldProvider: LineFoldProvider,
        controller: TextViewController,
        documentVersion: LineFoldDocumentVersion,
        textChangedStream: AsyncStream<Void>
    ) {
        // This could be grabbed from the controller, but Swift 6 doesn't like that (concurrency safety)
        self.foldProvider = foldProvider
        self.controller = controller
        self.documentVersion = documentVersion
        (valueStream, valueStreamContinuation) = AsyncStream<LineFoldPass>.makeStream()
        Task { await listenToTextChanges(textChangedStream: textChangedStream) }
    }

    deinit {
        textChangedTask?.cancel()
    }

    private func listenToTextChanges(textChangedStream: AsyncStream<Void>) {
        textChangedTask = Task {
            for await _ in textChangedStream {
                await buildFoldsForDocument()
            }
        }
    }

    private func buildFoldsForDocument() async {
        guard let controller = self.controller, let foldProvider = self.foldProvider else { return }
        let start = await Self.startPass(
            controller: controller,
            foldProvider: foldProvider,
            documentVersion: documentVersion
        )
        guard start.documentRange.length <= start.sizeLimit else {
            valueStreamContinuation.yield(
                LineFoldPass(
                    storage: LineFoldStorage(documentLength: start.documentRange.length),
                    documentVersion: start.documentVersion
                )
            )
            return
        }

        let folds: [LineFoldStorage.RawFold]
        if let scanner = start.scanner, let text = start.text {
            folds = scanner(text).map { LineFoldStorage.RawFold(depth: $0.depth, range: $0.range) }
        } else {
            folds = await walkLines(controller: controller, foldProvider: foldProvider, documentRange: start.documentRange)
        }

        await yieldNewStorage(
            newFolds: folds,
            controller: controller,
            documentRange: start.documentRange,
            documentVersion: start.documentVersion
        )
    }

    // Bridging the storage's mutable string gives an immutable copy, so the scanner can read it from the calculator's
    // own executor while the main thread goes on editing.
    @MainActor
    private static func startPass(
        controller: TextViewController,
        foldProvider: LineFoldProvider,
        documentVersion: LineFoldDocumentVersion
    ) -> PassStart {
        let documentRange = controller.textView.documentRange
        let sizeLimit = controller.configuration.peripherals.foldingSizeLimit
        let scanner = documentRange.length <= sizeLimit ? foldProvider.documentFoldScanner() : nil
        return PassStart(
            documentRange: documentRange,
            sizeLimit: sizeLimit,
            documentVersion: documentVersion.value,
            scanner: scanner,
            text: scanner == nil ? nil : controller.textView.textStorage.string
        )
    }

    private func walkLines(
        controller: TextViewController,
        foldProvider: LineFoldProvider,
        documentRange: NSRange
    ) async -> [LineFoldStorage.RawFold] {
        var foldCache: [LineFoldStorage.RawFold] = []
        // Depth: Open range
        var openFolds: [Int: LineFoldStorage.RawFold] = [:]
        var currentDepth: Int = 0
        let lineIterator = await ChunkedLineIterator(
            controller: controller,
            foldProvider: foldProvider,
            textIterator: await controller.textView.layoutManager.lineStorage.makeIterator()
        )

        for await lineChunk in lineIterator {
            for lineInfo in lineChunk {
                // Start a new fold, going deeper to a new depth.
                if lineInfo.depth > currentDepth {
                    let newFold = LineFoldStorage.RawFold(
                        depth: lineInfo.depth,
                        range: lineInfo.rangeIndice..<lineInfo.rangeIndice
                    )
                    openFolds[newFold.depth] = newFold
                } else if lineInfo.depth < currentDepth {
                    // End open folds > received depth
                    for openFold in openFolds.values.filter({ $0.depth > lineInfo.depth }) {
                        openFolds.removeValue(forKey: openFold.depth)
                        foldCache.append(
                            LineFoldStorage.RawFold(
                                depth: openFold.depth,
                                range: openFold.range.lowerBound..<lineInfo.rangeIndice
                            )
                        )
                    }
                }

                currentDepth = lineInfo.depth
            }
        }

        // Clean up any hanging folds.
        for fold in openFolds.values {
            foldCache.append(
                LineFoldStorage.RawFold(
                    depth: fold.depth,
                    range: fold.range.lowerBound..<documentRange.length
                )
            )
        }
        return foldCache
    }

    private func yieldNewStorage(
        newFolds: [LineFoldStorage.RawFold],
        controller: TextViewController,
        documentRange: NSRange,
        documentVersion: Int
    ) async {
        let attachments = await controller.textView.layoutManager.attachments
            .getAttachmentsOverlapping(documentRange)
            .compactMap { attachmentBox -> LineFoldStorage.DepthStartPair? in
                guard let attachment = attachmentBox.attachment as? LineFoldPlaceholder else {
                    return nil
                }
                return LineFoldStorage.DepthStartPair(depth: attachment.fold.depth, start: attachmentBox.range.location)
            }

        let storage = LineFoldStorage(
            documentLength: newFolds.max(
                by: { $0.range.upperBound < $1.range.upperBound }
            )?.range.upperBound ?? documentRange.length,
            // The store keeps the fold set last where two overlap, so of folds that start together the outermost goes
            // last and is the one shown, whichever order the provider reported them in.
            folds: newFolds.sorted {
                $0.range.lowerBound == $1.range.lowerBound ? $0.depth > $1.depth : $0.range.lowerBound < $1.range.lowerBound
            },
            collapsedRanges: Set(attachments)
        )
        valueStreamContinuation.yield(LineFoldPass(storage: storage, documentVersion: documentVersion))
    }

    // An `AsyncSequence` so the provider's per-line calls run on the main actor, where the text storage lives.
    @MainActor
    struct ChunkedLineIterator: AsyncSequence, AsyncIteratorProtocol {
        var controller: TextViewController
        var foldProvider: LineFoldProvider
        private var previousDepth: Int = 0
        var textIterator: TextLineStorage<TextLine>.TextLineStorageIterator

        init(
            controller: TextViewController,
            foldProvider: LineFoldProvider,
            textIterator: TextLineStorage<TextLine>.TextLineStorageIterator
        ) {
            self.controller = controller
            self.foldProvider = foldProvider
            self.textIterator = textIterator
        }

        nonisolated func makeAsyncIterator() -> ChunkedLineIterator {
            self
        }

        mutating func next() -> [LineFoldProviderLineInfo]? {
            var results: [LineFoldProviderLineInfo] = []
            var count = 0
            while count < 50, let linePosition = textIterator.next() {
                let foldInfo = foldProvider.foldLevelAtLine(
                    lineNumber: linePosition.index,
                    lineRange: linePosition.range,
                    previousDepth: previousDepth,
                    controller: controller
                )
                results.append(contentsOf: foldInfo)
                count += 1
                previousDepth = foldInfo.max(by: { $0.depth < $1.depth })?.depth ?? previousDepth
            }
            if results.isEmpty && count == 0 {
                return nil
            }
            return results
        }
    }
}
