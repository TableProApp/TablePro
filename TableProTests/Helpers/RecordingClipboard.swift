import AppKit
@testable import TablePro
import Testing

/// Each write replaces what the clipboard held, as `clearContents()` does in the real provider.
@MainActor
final class RecordingClipboard: ClipboardProvider {
    @TaskLocal static var current: RecordingClipboard?

    var text: String?
    var gridRows: GridRowsClipboardPayload?
    var gridCells: GridCellsClipboardPayload?
    private(set) var html: String?
    private(set) var writes: [String] = []
    private(set) var images: [NSImage] = []

    var hasText: Bool { text != nil }
    var hasGridRows: Bool { gridRows != nil }

    func readText() -> String? { text }
    func readGridRows() -> GridRowsClipboardPayload? { gridRows }
    func readGridCells() -> GridCellsClipboardPayload? { gridCells }

    func writeText(_ text: String) { replace(text: text) }
    func writeCsv(_ csv: String) { replace(text: csv) }

    func writeImage(_ image: NSImage) {
        replace(text: nil)
        images.append(image)
    }

    func writeRows(tsv: String, html: String?, gridRows: GridRowsClipboardPayload) {
        replace(text: tsv, html: html, gridRows: gridRows)
    }

    func writeCells(_ cells: GridCellsClipboardPayload) {
        replace(text: cells.text, gridCells: cells)
    }

    private func replace(
        text: String?,
        html: String? = nil,
        gridRows: GridRowsClipboardPayload? = nil,
        gridCells: GridCellsClipboardPayload? = nil
    ) {
        self.text = text
        self.html = html
        self.gridRows = gridRows
        self.gridCells = gridCells
        if let text { writes.append(text) }
    }
}

/// Swaps the real global, so AppKit callbacks such as menu actions write to the fake too; the
/// task-local only hands the fake to the case body. A user nests under `GlobalStateSuites`.
struct RecordingClipboardTrait: TestTrait, SuiteTrait, TestScoping {
    var isRecursive: Bool { true }

    @MainActor
    func provideScope(
        for test: Test,
        testCase: Test.Case?,
        performing function: @concurrent @Sendable () async throws -> Void
    ) async throws {
        let fake = RecordingClipboard()
        let previous = ClipboardService.shared
        ClipboardService.shared = fake
        defer { ClipboardService.shared = previous }
        try await RecordingClipboard.$current.withValue(fake) {
            try await function()
        }
    }
}

extension Trait where Self == RecordingClipboardTrait {
    static var recordingClipboard: Self { Self() }
}
