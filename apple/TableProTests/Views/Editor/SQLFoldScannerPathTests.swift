import AppKit
import Combine
import Darwin
import Foundation
@testable import TablePro
@testable import TableProEditorKit
import TableProGrammars
import TableProSQLGrammar
import TableProTestSupport
import TableProTextEngine
import TableProUtilities
import Testing

// SQL folding runs `SQLFoldScanner` off the main thread on a copy of the text. These hold that path to the folds the
// per-line walk gives, and the main thread to a copy per keystroke instead of a scan.
// Serialized: the keystroke case reads the main thread's CPU time, which a case running beside it would add to.
@MainActor
@Suite(.serialized)
struct SQLFoldScannerPathTests {
    @MainActor
    private final class LineWalkOnly: LineFoldProvider {
        private let base: SQLLineFoldProvider

        init(grammar: SQLLexicalGrammar) {
            base = SQLLineFoldProvider(grammar: grammar)
        }

        func foldLevelAtLine(
            lineNumber: Int,
            lineRange: NSRange,
            previousDepth: Int,
            controller: TextViewController
        ) -> [LineFoldProviderLineInfo] {
            base.foldLevelAtLine(
                lineNumber: lineNumber,
                lineRange: lineRange,
                previousDepth: previousDepth,
                controller: controller
            )
        }
    }

    private struct Fold: Equatable {
        let depth: Int
        let range: Range<Int>
    }

    private static let mixedScript = """
        CREATE TABLE users (
          id INT PRIMARY KEY,
          name TEXT,
          CHECK (
            id > 0
          )
        );
        /* a comment
           over lines */
        SELECT id,
               CASE
                 WHEN id > 1 THEN 'a'
                 ELSE 'b'
               END AS label
          FROM users
         WHERE id IN (
           SELECT id FROM users
         );
        DO $$
        BEGIN
          PERFORM 1;
        END
        $$;
        SELECT 1; SELECT (2);
        INSERT INTO users VALUES
          (1, 'a'),
          (2, 'b');
        """

    private func makeController(text: String, provider: LineFoldProvider) -> TextViewController {
        let controller = TextViewController(
            string: text,
            language: .sql,
            configuration: SourceEditorConfiguration(
                appearance: .init(
                    theme: ThemeEngine.shared.makeEditorTheme(),
                    font: .monospacedSystemFont(ofSize: 12, weight: .regular),
                    wrapLines: false
                ),
                peripherals: .init(foldingSizeLimit: StatementRunController.defaultSizeLimit)
            ),
            cursorPositions: [],
            highlightProviders: [],
            foldProvider: provider
        )
        controller.loadView()
        controller.view.frame = NSRect(x: 0, y: 0, width: 1_000, height: 1_000)
        controller.view.layoutSubtreeIfNeeded()
        return controller
    }

    private func folds(in controller: TextViewController) -> [Fold] {
        controller.foldModel?
            .getFolds(in: 0..<controller.textView.textStorage.length)
            .map { Fold(depth: $0.depth, range: $0.range) } ?? []
    }

    private static func mainThreadCPUMilliseconds() -> Double {
        var info = thread_basic_info()
        var count = mach_msg_type_number_t(MemoryLayout<thread_basic_info>.size / MemoryLayout<natural_t>.size)
        let thread = pthread_mach_thread_np(pthread_self())
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                thread_info(thread, thread_flavor_t(THREAD_BASIC_INFO), $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return 0 }
        return Double(info.user_time.seconds + info.system_time.seconds) * 1_000
            + Double(info.user_time.microseconds + info.system_time.microseconds) / 1_000
    }

    @Test("The scanner path folds a script the way the per-line walk does", arguments: ["\n", "\r\n"])
    func scannerMatchesLineWalk(lineEnding: String) async throws {
        let text = Self.mixedScript.replacingOccurrences(of: "\n", with: lineEnding)
        let scanned = makeController(text: text, provider: SQLLineFoldProvider(grammar: TestGrammar.postgres))
        let walked = makeController(text: text, provider: LineWalkOnly(grammar: TestGrammar.postgres))

        try await waitUntil(timeout: .seconds(30)) { !folds(in: scanned).isEmpty && !folds(in: walked).isEmpty }

        #expect(folds(in: walked).count >= 6)
        #expect(folds(in: scanned) == folds(in: walked))
    }

    // A pass used to walk every line through the provider on the main thread, the scan included; now the main thread
    // only copies the text and takes the result. Both are timed on the same document in the same run, so a slow runner
    // moves both sides. Long single-line statements keep the fold count, and the Debug fold store's fill time, low.
    @Test("A fold pass costs the main thread a fraction of the per-line walk")
    func passCostsAFractionOfTheWalk() async throws {
        let statement = "SELECT '" + String(repeating: "x", count: 180) + "' FROM t;\n"
        let block = "CREATE TABLE t (\n  id INT\n);\n" + String(repeating: statement, count: 20)
        let text = String(repeating: block, count: 300_000 / (block as NSString).length)
        #expect((text as NSString).length > LineFoldModel.immediateRecalculationLimit)

        let walked = TextViewController(string: text, language: .sql, configuration: configuration, cursorPositions: [])
        let walker = SQLLineFoldProvider(grammar: TestGrammar.postgres)
        var walkCosts: [Double] = []
        for _ in 0..<3 {
            var lines = walked.textView.layoutManager.lineStorage.makeIterator()
            let start = Self.mainThreadCPUMilliseconds()
            while let line = lines.next() {
                _ = walker.foldLevelAtLine(
                    lineNumber: line.index, lineRange: line.range, previousDepth: 0, controller: walked
                )
            }
            walkCosts.append(Self.mainThreadCPUMilliseconds() - start)
        }

        let scanned = TextViewController(
            string: text,
            language: .sql,
            configuration: configuration,
            cursorPositions: [],
            foldProvider: SQLLineFoldProvider(grammar: TestGrammar.postgres)
        )
        let model = LineFoldModel(controller: scanned, foldView: NSView())
        defer { model.destroy() }
        try await waitUntil(timeout: .seconds(30)) { !model.getFolds(in: 0..<(text as NSString).length).isEmpty }
        // Awaited, not polled: polling while the pass runs would bill the main thread for the wait.
        let (published, publish) = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
        let subscription = model.$foldCache.dropFirst().sink { _ in publish.yield() }
        defer { subscription.cancel() }
        var passCosts: [Double] = []
        for _ in 0..<3 {
            let start = Self.mainThreadCPUMilliseconds()
            model.refresh()
            for await _ in published { break }
            passCosts.append(Self.mainThreadCPUMilliseconds() - start)
        }

        let walk = walkCosts.sorted()[1]
        let pass = passCosts.sorted()[1]
        #expect(pass < walk / 4, "a pass took \(pass) ms of main thread, the walk \(walk) ms")
    }

    private var configuration: SourceEditorConfiguration {
        SourceEditorConfiguration(
            appearance: .init(
                theme: ThemeEngine.shared.makeEditorTheme(),
                font: .monospacedSystemFont(ofSize: 12, weight: .regular),
                wrapLines: false
            ),
            peripherals: .init(foldingSizeLimit: StatementRunController.defaultSizeLimit)
        )
    }
}
