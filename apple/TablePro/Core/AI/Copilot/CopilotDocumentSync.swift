import AppKit
import os
import TableProTextEngine

@MainActor
final class CopilotDocumentSync {
    private enum Outgoing {
        case open(uri: String, text: String, generation: Int)
        case change(uri: String, changes: [LSPTextDocumentContentChangeEvent], generation: Int)
        case focus(uri: String, generation: Int)
        case close(uri: String, generation: Int)

        var generation: Int {
            switch self {
            case .open(_, _, let generation), .change(_, _, let generation),
                 .focus(_, let generation), .close(_, let generation):
                generation
            }
        }
    }

    private struct OpenDocument {
        let uri: String
        let generation: Int
    }

    nonisolated private static let logger = Logger(subsystem: "com.TablePro", category: "CopilotDocumentSync")
    private static let carriageReturn: unichar = 0x0D
    private static let lineFeed: unichar = 0x0A

    let preambleBuilder = CopilotPreambleBuilder()
    private let server: any CopilotDocumentServer
    private let lengthLimit: Int
    private let documentManager = LSPDocumentManager()
    // Every editor talks to the one server, so a document number is never reused by another editor's sync.
    private static var nextDocumentNumber = 1
    private var uriMap: [UUID: String] = [:]

    private var openDocument: OpenDocument?
    private var needsFullText = false
    private var mayContainCarriageReturn = false
    private var linesMayDisagree = false
    private var lineCheckTask: Task<Void, Never>?

    private var outbox: [Outgoing] = []
    private var drainTask: Task<Void, Never>?

    private weak var textView: TextView?
    private weak var observedStorage: NSTextStorage?
    private var editObservation: CopilotEditObservation?
    private var currentTabID: @MainActor () -> UUID? = { nil }
    private var isAllowed: @MainActor () -> Bool = { false }
    private var schemaSource: @MainActor () -> CopilotPreambleBuilder.Source? = { nil }
    private var preambleRebuild: Task<Void, Never>?

    init(server: any CopilotDocumentServer, lengthLimit: Int) {
        self.server = server
        self.lengthLimit = lengthLimit
    }

    func documentURI(for tabID: UUID) -> String {
        if let existing = uriMap[tabID] { return existing }
        let fileURL = CopilotPreambleBuilder.contextDirectory
            .appendingPathComponent("query-\(Self.nextDocumentNumber).sql")
        Self.nextDocumentNumber += 1
        let uri = fileURL.absoluteString
        uriMap[tabID] = uri
        return uri
    }

    // MARK: - Editor

    func attach(
        to textView: TextView,
        tabID: @escaping @MainActor () -> UUID?,
        isAllowed: @escaping @MainActor () -> Bool,
        schemaSource: @escaping @MainActor () -> CopilotPreambleBuilder.Source?
    ) {
        self.textView = textView
        currentTabID = tabID
        self.isAllowed = isAllowed
        self.schemaSource = schemaSource
        guard let storage = textView.textStorage, let lines = textView.layoutManager?.lineStorage else { return }
        observe(storage)
        // Edits made before this observer existed can have left the line storage off the server's lines.
        if storage.mutableString.range(of: "\r", options: .literal).location != NSNotFound {
            linesMayDisagree = !lines.breaksLines(like: storage.mutableString)
        }
        synchronize(from: storage)
    }

    // Only a tab the user types in, or asks a suggestion in, reaches the server.
    func textViewDidReplaceDocument() {
        guard let storage = textView?.textStorage else { return }
        observe(storage)
        needsFullText = true
    }

    func detach() {
        preambleRebuild?.cancel()
        preambleRebuild = nil
        editObservation = nil
        observedStorage = nil
        textView = nil
        currentTabID = { nil }
        isAllowed = { false }
        schemaSource = { nil }
        guard let open = openDocument else { return }
        openDocument = nil
        enqueue(.close(uri: open.uri, generation: open.generation))
    }

    func activate(tabID: UUID, text: String) {
        guard canSend(length: text.utf16.count) else {
            needsFullText = true
            return
        }
        let uri = documentURI(for: tabID)
        let generation = server.generation
        if let open = openDocument, open.uri != uri {
            enqueue(.close(uri: open.uri, generation: open.generation))
            openDocument = nil
        }
        sendFullText(text, uri: uri, generation: generation)
        enqueue(.focus(uri: uri, generation: generation))
    }

    // MARK: - Server

    // Column reads can queue behind a running query, so a request never waits on them; the next sync sends the result.
    func refreshPreamble(forStatementAt cursorOffset: Int, in text: String) {
        guard preambleRebuild == nil, textView != nil, isAllowed(), let source = schemaSource() else { return }
        preambleRebuild = Task { [weak self] in
            guard let self else { return }
            let rebuilt = await self.preambleBuilder.rebuiltPreamble(forStatementAt: cursorOffset, in: text, from: source)
            self.preambleRebuild = nil
            guard !Task.isCancelled, let rebuilt else { return }
            let changesText = rebuilt.preamble != self.preambleBuilder.preamble
            guard self.preambleBuilder.adopt(rebuilt), changesText else { return }
            // Set with the new preamble, so no edit is placed with its line count against a document that has the old one.
            self.needsFullText = true
        }
    }

    func flush() async {
        if lineCheckTask != nil {
            checkLines()
        }
        resynchronizeIfStale()
        while let task = drainTask {
            await task.value
        }
    }

    func currentDocumentInfo() -> (uri: String, version: Int)? {
        guard let open = openDocument, !needsFullText, outbox.isEmpty, drainTask == nil,
              open.generation == server.generation,
              let tabID = currentTabID(), uriMap[tabID] == open.uri,
              let version = documentManager.version(for: open.uri) else { return nil }
        return (open.uri, version)
    }

    // MARK: - Edits

    private func observe(_ storage: NSTextStorage) {
        observedStorage = storage
        linesMayDisagree = false
        // Every way the text changes passes through the storage, the typing filters' edits included.
        let token = NotificationCenter.default.addObserver(
            forName: NSTextStorage.willProcessEditingNotification,
            object: storage,
            queue: nil
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.storageWillProcessEditing() }
        }
        editObservation = CopilotEditObservation(token)
    }

    private func storageWillProcessEditing() {
        guard let storage = observedStorage, storage.editedMask.contains(.editedCharacters) else { return }
        guard textView?.textStorage === storage else {
            needsFullText = true
            return
        }
        guard let tabID = currentTabID(), canSend(length: storage.length) else {
            needsFullText = true
            return
        }
        let uri = documentURI(for: tabID)
        guard let open = openDocument, open.uri == uri, open.generation == server.generation else {
            activate(tabID: tabID, text: storage.string)
            return
        }
        guard !needsFullText, let change = incrementalChange(in: storage) else {
            sendFullText(storage.string, uri: uri, generation: open.generation)
            return
        }
        enqueueChange(change, uri: uri, generation: open.generation)
    }

    private func incrementalChange(in storage: NSTextStorage) -> LSPTextDocumentContentChangeEvent? {
        guard let lines = textView?.layoutManager?.lineStorage else { return nil }
        let editedRange = storage.editedRange
        let replacedLength = editedRange.length - storage.changeInLength
        // The layout manager updates its lines after this notification, so they still describe the text before the edit.
        guard lines.length == storage.length - storage.changeInLength else {
            Self.logger.debug("Line storage out of step with the edit, sending the full text")
            return nil
        }
        let text = storage.mutableString
        let inserted = text.substring(with: editedRange)
        if inserted.utf16.contains(Self.carriageReturn) {
            mayContainCarriageReturn = true
        }
        if mayContainCarriageReturn {
            if Self.touchesLineBreakPair(in: text, editedRange: editedRange, replacedLength: replacedLength) {
                linesMayDisagree = true
            }
            if linesMayDisagree { return nil }
        }
        let lineOffset = preambleBuilder.preambleLineCount
        guard let start = Self.position(of: editedRange.location, in: lines, lineOffset: lineOffset),
              let end = Self.position(of: editedRange.location + replacedLength, in: lines, lineOffset: lineOffset) else {
            return nil
        }
        return LSPTextDocumentContentChangeEvent(range: LSPRange(start: start, end: end), text: inserted)
    }

    // The server clamps a position between CR and LF to before the CR, and the editor's line storage splits or joins a
    // CR LF pair an edit crosses, so such an edit sends the full text, as does every later one until no CR is left.
    private static func touchesLineBreakPair(in text: NSString, editedRange: NSRange, replacedLength: Int) -> Bool {
        if editedRange.location > 0, text.character(at: editedRange.location - 1) == carriageReturn {
            return true
        }
        let end = NSMaxRange(editedRange)
        guard end < text.length, text.character(at: end) == lineFeed else { return false }
        return replacedLength > 0 || (editedRange.length > 0 && text.character(at: end - 1) == carriageReturn)
    }

    private static func position(of offset: Int, in lines: TextLineStorage<TextLine>, lineOffset: Int) -> LSPPosition? {
        guard let line = offset == lines.length ? lines.last : lines.getLine(atOffset: offset) else { return nil }
        return LSPPosition(line: line.index + lineOffset, character: offset - line.range.location)
    }

    // MARK: - Full Text

    private func canSend(length: Int) -> Bool {
        length <= lengthLimit && server.hasClient && isAllowed()
    }

    private func synchronize(from storage: NSTextStorage) {
        guard let tabID = currentTabID(), canSend(length: storage.length) else {
            needsFullText = true
            return
        }
        let uri = documentURI(for: tabID)
        if let open = openDocument, open.uri == uri, open.generation == server.generation {
            sendFullText(storage.string, uri: uri, generation: open.generation)
        } else {
            activate(tabID: tabID, text: storage.string)
        }
    }

    private func resynchronizeIfStale() {
        guard let storage = textView?.textStorage else { return }
        if storage !== observedStorage {
            observe(storage)
            needsFullText = true
        }
        guard let tabID = currentTabID() else { return }
        if let open = openDocument, open.uri == uriMap[tabID], open.generation == server.generation, !needsFullText {
            return
        }
        synchronize(from: storage)
    }

    private func sendFullText(_ text: String, uri: String, generation: Int) {
        mayContainCarriageReturn = (text as NSString).range(of: "\r", options: .literal).location != NSNotFound
        if !mayContainCarriageReturn {
            linesMayDisagree = false
        } else if linesMayDisagree {
            scheduleLineCheck()
        }
        needsFullText = false
        let fullText = preambleBuilder.prependToText(text)
        if let open = openDocument, open.uri == uri, open.generation == generation {
            enqueueChange(LSPTextDocumentContentChangeEvent(text: fullText), uri: uri, generation: generation)
        } else {
            openDocument = OpenDocument(uri: uri, generation: generation)
            enqueue(.open(uri: uri, text: fullText, generation: generation))
        }
    }

    // The storage notifies before the layout manager takes an edit in, so the check runs once the edit is done.
    private func scheduleLineCheck() {
        guard lineCheckTask == nil else { return }
        lineCheckTask = Task { [weak self] in
            guard !Task.isCancelled else { return }
            self?.checkLines()
        }
    }

    // Every edit since the last full text went out as full text, so lines that follow the text now follow the server's.
    private func checkLines() {
        lineCheckTask?.cancel()
        lineCheckTask = nil
        guard linesMayDisagree, let textView, let storage = textView.textStorage, storage === observedStorage,
              storage.editedMask.isEmpty, let lines = textView.layoutManager?.lineStorage else { return }
        linesMayDisagree = !lines.breaksLines(like: storage.mutableString)
    }

    // MARK: - Outbox

    private func enqueue(_ message: Outgoing) {
        outbox.append(message)
        scheduleDrain()
    }

    private func enqueueChange(_ change: LSPTextDocumentContentChangeEvent, uri: String, generation: Int) {
        if change.range == nil {
            outbox.removeAll { message in
                if case .change(let queuedURI, _, _) = message { return queuedURI == uri }
                return false
            }
        }
        if case .change(let lastURI, let changes, let lastGeneration)? = outbox.last,
           lastURI == uri, lastGeneration == generation {
            outbox[outbox.count - 1] = .change(uri: uri, changes: changes + [change], generation: generation)
            return
        }
        enqueue(.change(uri: uri, changes: [change], generation: generation))
    }

    // One task sends everything in edit order; a task per notification gives no order between them.
    private func scheduleDrain() {
        guard drainTask == nil else { return }
        drainTask = Task {
            await self.drainOutbox()
        }
    }

    private func drainOutbox() async {
        while !outbox.isEmpty {
            await send(outbox.removeFirst())
        }
        drainTask = nil
    }

    private func send(_ message: Outgoing) async {
        guard server.hasClient, server.generation == message.generation else { return }
        switch message {
        case let .close(uri, _):
            guard documentManager.closeDocument(uri: uri) != nil else { return }
            await server.didClose(uri: uri)
        case let .open(uri, _, generation) where !isAllowed():
            if openDocument?.uri == uri, openDocument?.generation == generation {
                openDocument = nil
            }
        case .change where !isAllowed():
            needsFullText = true
        case .focus where !isAllowed():
            break
        case let .open(uri, text, _):
            await server.didOpen(documentManager.openDocument(uri: uri, languageId: "sql", text: text))
        case let .change(uri, changes, _):
            guard let params = documentManager.changeDocument(uri: uri, changes: changes) else { return }
            await server.didChange(params)
        case let .focus(uri, _):
            await server.didFocus(uri: uri)
        }
    }
}

private final class CopilotEditObservation {
    private let token: any NSObjectProtocol

    init(_ token: any NSObjectProtocol) {
        self.token = token
    }

    deinit {
        NotificationCenter.default.removeObserver(token)
    }
}
