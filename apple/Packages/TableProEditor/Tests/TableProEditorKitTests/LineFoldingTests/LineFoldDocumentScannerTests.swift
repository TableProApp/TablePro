import AppKit
import Combine
@testable import TableProEditorKit
import TableProTestSupport
import TableProTextEngine
import Testing

// A provider with a whole-document scanner is folded off the main thread from a copy of the text, so these hold that
// path to the folds the per-line walk builds, and to the document version the model checks before taking a result.
@MainActor
struct LineFoldDocumentScannerTests {
    struct Region: Equatable {
        let depth: Int
        let range: Range<Int>
        let startLine: Int
        let endLine: Int
    }

    struct Fold: Equatable {
        let depth: Int
        let range: Range<Int>
    }

    final class ScanLog: @unchecked Sendable {
        private let lock = NSLock()
        private var started = 0
        private var finished = 0
        private var read: [[UInt16]] = []
        let gate: DispatchSemaphore?

        init(gated: Bool = false) {
            gate = gated ? DispatchSemaphore(value: 0) : nil
        }

        var startedCount: Int {
            lock.withLock { started }
        }

        var count: Int {
            lock.withLock { finished }
        }

        var texts: [[UInt16]] {
            lock.withLock { read }
        }

        func scan(_ text: String) -> [LineFoldProviderFold] {
            lock.withLock { started += 1 }
            gate?.wait()
            // Read after the wait, so a held pass shows whether its copy moved with the edits made meanwhile.
            let snapshot = Array(text.utf16)
            defer { lock.withLock { finished += 1; read.append(snapshot) } }
            return LineFoldDocumentScannerTests.regions(in: text).map {
                LineFoldProviderFold(depth: $0.depth, range: $0.range)
            }
        }
    }

    // Braces nest the way a SQL scanner's frames do: a region that opens and closes on one line folds nothing.
    nonisolated static func regions(in text: String) -> [Region] {
        var stack: [(start: Int, line: Int)] = []
        var line = 0
        var regions: [Region] = []
        for (offset, unit) in text.utf16.enumerated() {
            switch unit {
            case 0x0A:
                line += 1
            case 0x7B:
                stack.append((offset + 1, line))
            case 0x7D:
                guard let open = stack.popLast(), open.line != line else { continue }
                regions.append(
                    Region(depth: stack.count + 1, range: open.start..<offset, startLine: open.line, endLine: line)
                )
            default:
                break
            }
        }
        return regions
    }

    @MainActor
    final class BraceFoldProvider: LineFoldProvider {
        let offersScanner: Bool
        let log: ScanLog
        private var regions: [Region] = []

        init(offersScanner: Bool, log: ScanLog = ScanLog()) {
            self.offersScanner = offersScanner
            self.log = log
        }

        func documentFoldScanner() -> LineFoldDocumentScanner? {
            guard offersScanner else { return nil }
            let log = log
            return { text in log.scan(text) }
        }

        func foldLevelAtLine(
            lineNumber: Int,
            lineRange: NSRange,
            previousDepth: Int,
            controller: TextViewController
        ) -> [LineFoldProviderLineInfo] {
            if lineNumber == 0 {
                regions = LineFoldDocumentScannerTests.regions(in: controller.textView.string)
            }
            let ends = regions.filter { $0.endLine == lineNumber }.sorted { $0.depth > $1.depth }
            let starts = regions.filter { $0.startLine == lineNumber }.sorted { $0.depth < $1.depth }
            return ends.map { .endFold(rangeEnd: $0.range.upperBound, newDepth: $0.depth - 1) }
                + starts.map { .startFold(rangeStart: $0.range.lowerBound, newDepth: $0.depth) }
        }
    }

    // A statement and its parenthesised body both fold from the end of `CREATE TABLE t (`.
    @MainActor
    final class SharedStartProvider: LineFoldProvider {
        let offersScanner: Bool
        private let regions = [
            Region(depth: 1, range: 2..<7, startLine: 0, endLine: 2),
            Region(depth: 2, range: 2..<6, startLine: 0, endLine: 2),
        ]

        init(offersScanner: Bool) {
            self.offersScanner = offersScanner
        }

        func documentFoldScanner() -> LineFoldDocumentScanner? {
            guard offersScanner else { return nil }
            let folds = regions.map { LineFoldProviderFold(depth: $0.depth, range: $0.range) }
            return { _ in folds }
        }

        func foldLevelAtLine(
            lineNumber: Int,
            lineRange: NSRange,
            previousDepth: Int,
            controller: TextViewController
        ) -> [LineFoldProviderLineInfo] {
            let ends = regions.filter { $0.endLine == lineNumber }.sorted { $0.depth > $1.depth }
            let starts = regions.filter { $0.startLine == lineNumber }.sorted { $0.depth < $1.depth }
            return ends.map { .endFold(rangeEnd: $0.range.upperBound, newDepth: $0.depth - 1) }
                + starts.map { .startFold(rangeStart: $0.range.lowerBound, newDepth: $0.depth) }
        }
    }

    private static let nestedDocument: String = (0..<40).map { index in
        switch index % 4 {
        case 0: return "block \(index) {\n  inner {\n    x\n  }\n  y\n}"
        case 1: return "flat \(index) { same line }"
        case 2: return "deep {\n {\n  {\n   z\n  }\n }\n}"
        default: return "open {\n  a\n} close { b\n}"
        }
    }.joined(separator: "\n")

    private func makeController(_ text: String, provider: LineFoldProvider) -> TextViewController {
        let controller = Mock.textViewController(theme: Mock.theme())
        controller.textView.string = text
        controller.textView.frame = NSRect(x: 0, y: 0, width: 1_000, height: 1_000)
        controller.textView.updatedViewport(NSRect(x: 0, y: 0, width: 1_000, height: 1_000))
        controller.foldProvider = provider
        return controller
    }

    private func folds(of model: LineFoldModel, in controller: TextViewController) -> [Fold] {
        model.getFolds(in: 0..<controller.textView.textStorage.length).map { Fold(depth: $0.depth, range: $0.range) }
    }

    private func expected(_ text: String) -> [Fold] {
        Self.regions(in: text)
            .map { Fold(depth: $0.depth, range: $0.range) }
            .sorted { $0.range.lowerBound < $1.range.lowerBound }
    }

    @Test("The scanner path builds the same folds as the per-line walk")
    func scannerMatchesLineWalk() async throws {
        let walking = makeController(Self.nestedDocument, provider: BraceFoldProvider(offersScanner: false))
        let scanning = makeController(Self.nestedDocument, provider: BraceFoldProvider(offersScanner: true))
        let walkModel = LineFoldModel(controller: walking, foldView: NSView())
        let scanModel = LineFoldModel(controller: scanning, foldView: NSView())

        try await waitUntil(timeout: .seconds(60)) {
            !folds(of: walkModel, in: walking).isEmpty && !folds(of: scanModel, in: scanning).isEmpty
        }

        let walked = folds(of: walkModel, in: walking)
        #expect(walked.count > 20)
        #expect(folds(of: scanModel, in: scanning) == walked)
        #expect(walked == expected(Self.nestedDocument))
    }

    @Test("Of folds that start together, both paths show the outer one")
    func sharedStartShowsTheOuterFold() async throws {
        let text = "a(\n b\n);\n"
        let walking = makeController(text, provider: SharedStartProvider(offersScanner: false))
        let scanning = makeController(text, provider: SharedStartProvider(offersScanner: true))
        let walkModel = LineFoldModel(controller: walking, foldView: NSView())
        let scanModel = LineFoldModel(controller: scanning, foldView: NSView())

        try await waitUntil(timeout: .seconds(30)) {
            !folds(of: walkModel, in: walking).isEmpty && !folds(of: scanModel, in: scanning).isEmpty
        }

        #expect(folds(of: walkModel, in: walking) == [Fold(depth: 1, range: 2..<7)])
        #expect(folds(of: scanModel, in: scanning) == [Fold(depth: 1, range: 2..<7)])
    }

    @Test("A pass over text that changed before it landed is dropped")
    func stalePassIsDropped() async throws {
        let log = ScanLog(gated: true)
        // A failed wait must not leave a pool thread parked in the scanner for the rest of the run.
        defer {
            log.gate?.signal()
            log.gate?.signal()
        }
        let original = "a {\n b\n}\nc {\n d\n}\n"
        let controller = makeController(original, provider: BraceFoldProvider(offersScanner: true, log: log))
        let model = LineFoldModel(controller: controller, foldView: NSView())

        var published: [[Fold]] = []
        let subscription = model.$foldCache.sink { cache in
            published.append(cache.folds(in: 0..<Int.max).map { Fold(depth: $0.depth, range: $0.range) })
        }
        defer { subscription.cancel() }

        // The first pass has read the original text and is held inside the scanner.
        try await waitUntil(timeout: .seconds(30)) { log.startedCount == 1 }
        controller.textView.textStorage.replaceCharacters(in: NSRange(location: 0, length: 0), with: "{\nnew\n}\n")
        log.gate?.signal()
        log.gate?.signal()

        let edited = controller.textView.string
        try await waitUntil(timeout: .seconds(30)) { folds(of: model, in: controller) == expected(edited) }

        #expect(!published.contains(expected(original)), "The original text's folds were applied after the edit")
        #expect(log.texts.first == Array(original.utf16), "The held pass read text edited after it started")
    }

    @Test("A large document recomputes after the typing pause, a small one on the keystroke")
    func largeDocumentWaitsForThePause() async throws {
        let clock = ManualClock()
        let log = ScanLog()
        // Long lines with one fold: the size is what the debounce reads, and a Debug fold store fills slowly.
        let large = "x {\n y\n}\n" + String(repeating: String(repeating: "a", count: 99) + "\n", count: 700)
        #expect((large as NSString).length > LineFoldModel.immediateRecalculationLimit)
        let controller = makeController(large, provider: BraceFoldProvider(offersScanner: true, log: log))
        let model = LineFoldModel(controller: controller, foldView: NSView(), clock: clock)
        try await waitUntil(timeout: .seconds(20)) { log.count == 1 && !folds(of: model, in: controller).isEmpty }

        controller.textView.textStorage.replaceCharacters(in: NSRange(location: 0, length: 0), with: "z")
        await clock.waitUntilSleeping()
        #expect(log.count == 1)

        clock.advance(by: LineFoldModel.recalculationDelay)
        try await waitUntil(timeout: .seconds(20)) { log.count == 2 }

        let smallLog = ScanLog()
        let small = makeController("x {\n y\n}\n", provider: BraceFoldProvider(offersScanner: true, log: smallLog))
        let smallModel = LineFoldModel(controller: small, foldView: NSView(), clock: clock)
        try await waitUntil(timeout: .seconds(20)) { smallLog.count == 1 }
        small.textView.textStorage.replaceCharacters(in: NSRange(location: 0, length: 0), with: "z")
        try await waitUntil(timeout: .seconds(20)) { smallLog.count == 2 }
        _ = smallModel
    }
}
