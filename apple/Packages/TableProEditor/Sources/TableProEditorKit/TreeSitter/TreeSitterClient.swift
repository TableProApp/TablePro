//
//  TreeSitterClient.swift
//  TableProEditorKit
//
//  Created by Khan Winter on 9/12/22.
//

import Foundation
import OSLog
import SwiftTreeSitter
import TableProGrammars
import TableProTextEngine

/// # TreeSitterClient
///
/// ``TreeSitterClient`` is an class that manages a tree-sitter syntax tree and provides an API for notifying that
/// tree of edits and querying the tree. This type also conforms to ``HighlightProviding`` to provide syntax
/// highlighting.
///
/// The APIs this object provides can perform either asynchronously or synchronously. All calls to this object must
/// first be dispatched from the main queue to ensure serial access to internal properties. Any synchronous methods
/// can throw an ``TreeSitterClientExecutor/Error/syncUnavailable`` error if an asynchronous or synchronous call is
/// already being made on the object. In those cases it is up to the caller to decide whether or not to retry
/// asynchronously.
///
/// The only exception to the above rule is the ``HighlightProviding`` conformance methods. The methods for that
/// implementation may return synchronously or asynchronously depending on a variety of factors such as document
/// length, edit length, highlight length and if the object is available for a synchronous call.
public final class TreeSitterClient: HighlightProviding {
    static let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "", category: "TreeSitterClient")

    enum TreeSitterClientError: Error {
        case invalidEdit
    }

    // MARK: - Properties

    /// The parse pipeline's shared state. A background task reads it when it starts and commits to it, so neither
    /// the parse nor its commit waits for the main thread.
    struct Pipeline {
        /// The committed tree-sitter state.
        var state: TreeSitterState?
        /// The text `state` was parsed from, which queries read so their predicates see the text their tree saw.
        var stateText: TextSnapshot?
        /// Every edit `state` has not taken yet, in the order the main thread received them.
        var edits: [InputEdit] = []
        /// The text after every edit in `edits`.
        var text: TextSnapshot?
        /// Bumped by every edit and set up. A parse commits only while no edit has arrived since it read `text`.
        var revision = 0
        var setUpGeneration = 0
    }

    let pipeline = Atomic(Pipeline())

    /// The committed tree-sitter state.
    var state: TreeSitterState? {
        pipeline.withValue { $0.state }
    }

    /// Every edit the committed state has not taken yet.
    var pendingEdits: [InputEdit] {
        pipeline.withValue { $0.edits }
    }

    package var executor: TreeSitterExecutor = .init()

    /// Main thread only: the document's text, kept in step with every edit so a parse gets it without a copy.
    private var text: TextSnapshot?

    /// The end point of the previous edit.
    private var oldEndPoint: Point?

    /// Optional flag to force every operation to be done on the caller's thread.
    package var forceSyncOperation: Bool = false

    /// How long a parse may run on the main thread before a background task takes it over and resumes it.
    package var syncParseBudget: TimeInterval = 0.003

    static let signposter = OSSignposter(subsystem: "com.TablePro", category: "TreeSitter")

    /// Where an interval ran, so a trace separates the main thread's share.
    static var threadName: String {
        Thread.isMainThread ? "main" : "background"
    }

    // Old trees are freed here, so dropping a state never costs the main thread.
    private static let releaseQueue = DispatchQueue(label: "com.TablePro.TreeSitterClient.release", qos: .utility)

    static func releaseOffMain(_ state: TreeSitterState?) {
        guard let state, Thread.isMainThread else { return }
        releaseQueue.async {
            withExtendedLifetime(state) {}
        }
    }

    public init() { }

    // MARK: - Constants

    public enum Constants {
        /// The maximum amount of limits a cursor can match during a query.
        ///
        /// Used to ensure performance in large files, even though we generally limit the query to the visible range.
        /// Neovim encountered this issue and uses 64 for their limit. Helix uses 256 due to issues with some
        /// languages when using 64.
        /// See: [github.com/neovim](https://github.com/neovim/neovim/issues/14897)
        /// And: [github.com/helix-editor](https://github.com/helix-editor/helix/pull/4830)
        public static var matchLimit = 256

        /// The timeout for parsers to re-check if a task is canceled. This constant represents the period between
        /// checks and is directly related to editor responsiveness.
        public static var parserTimeout: TimeInterval = 0.05

        /// The maximum length of an edit before it must be processed asynchronously
        public static var maxSyncEditLength: Int = 1_024

        /// The maximum length a document can be before all queries and edits must be processed asynchronously.
        public static var maxSyncContentLength: Int = 1_000_000

        /// The maximum length a query can be before it must be performed asynchronously.
        public static var maxSyncQueryLength: Int = 4_096

        /// The number of characters to read in a read block.
        ///
        /// This has diminishing returns on the number of times the read block is called as this number gets large.
        public static let charsToReadInBlock: Int = 4_096

        /// The duration before a long parse notification is sent.
        public static var longParseTimeout: Duration = .seconds(0.5)

        /// The notification name sent when a long parse is detected.
        public static let longParse: Notification.Name = .init("TableProEditorKit.longParseNotification")

        /// The notification name sent when a long parse is finished.
        public static let longParseFinished: Notification.Name = .init(
            "TableProEditorKit.longParseFinishedNotification"
        )
    }

    // MARK: - HighlightProviding

    /// Set up the client with a text view and language.
    /// - Parameters:
    ///   - textView: The text view to use as a data source.
    ///               A weak reference will be kept for the lifetime of this object.
    ///   - codeLanguage: The language to use for parsing.
    public func setUp(textView: TextView, codeLanguage: CodeLanguage) {
        Self.logger.debug("TreeSitterClient setting up with language: \(codeLanguage.id.rawValue, privacy: .public)")

        let snapshot = Self.signposter.withIntervalSignpost("snapshot", "\(Self.threadName, privacy: .public)") {
            textView.createTextSnapshot()
        }
        text = snapshot
        // The committed state describes the text set up before this one, so it goes now: a caller that waits for a
        // state, or a parse task that starts on one, gets this set up's.
        let (generation, previous) = pipeline.mutate { pipeline in
            pipeline.setUpGeneration &+= 1
            pipeline.revision &+= 1
            pipeline.edits = []
            pipeline.text = snapshot
            let previous = pipeline.state
            pipeline.state = nil
            pipeline.stateText = nil
            return (pipeline.setUpGeneration, previous)
        }
        Self.releaseOffMain(previous)

        executor.cancelAll(below: .all)
        let operation = { [weak self] in
            let state = TreeSitterState(
                codeLanguage: codeLanguage,
                readCallback: snapshot.readCallback,
                readBlock: snapshot.readBlock
            )
            // Edits made after this set up stay pending: the next edit task applies them on top of this state.
            let replaced = self?.pipeline.mutate { pipeline -> TreeSitterState? in
                guard pipeline.setUpGeneration == generation else { return nil }
                let replaced = pipeline.state
                pipeline.state = state
                pipeline.stateText = snapshot
                return replaced
            }
            Self.releaseOffMain(replaced ?? nil)
        }
        if forceSyncOperation {
            executor.execSync(operation)
        } else {
            executor.execAsync(
                priority: .reset,
                operation: {
                    operation()
                    return true
                },
                onCancel: {}
            )
        }
    }

    // MARK: - HighlightProviding

    /// Decides whether an edit must be parsed asynchronously to keep the main thread responsive.
    ///
    /// The magnitude of an edit is the larger of the replaced range and the inserted length. Keying only on the
    /// replaced range misses a large paste at the caret, where the replaced range is empty but `delta` is huge, so a
    /// multi-megabyte insertion into a small document would otherwise run a full re-parse synchronously.
    /// - Parameters:
    ///   - editLength: The length of the range being replaced.
    ///   - delta: The change in length, negative for deletions.
    ///   - documentLength: The length of the document after the edit.
    /// - Returns: `true` when the edit should be parsed off the main thread.
    static func shouldExecuteAsync(editLength: Int, delta: Int, documentLength: Int) -> Bool {
        let editMagnitude = max(editLength, abs(delta))
        return editMagnitude > Constants.maxSyncEditLength || documentLength > Constants.maxSyncContentLength
    }

    /// Notifies the highlighter of an edit and in exchange gets a set of indices that need to be re-highlighted.
    /// The returned `IndexSet` should include all indexes that need to be highlighted, including any inserted text.
    /// - Parameters:
    ///   - textView: The text view to use.
    ///   - range: The range of the edit.
    ///   - delta: The length of the edit, can be negative for deletions.
    ///   - completion: The function to call with an `IndexSet` containing all Indices to invalidate.
    public func applyEdit(
        textView: TextView,
        range: NSRange,
        delta: Int,
        completion: @escaping @MainActor (Result<IndexSet, Error>) -> Void
    ) {
        let interval = Self.signposter.beginInterval("applyEdit", id: Self.signposter.makeSignpostID())
        defer { Self.signposter.endInterval("applyEdit", interval) }

        let snapshot = updatedText(textView: textView, range: range, delta: delta)
        let oldEndPoint: Point = self.oldEndPoint ?? textView.pointForLocation(range.max) ?? .zero
        let edit = InputEdit(range: range, delta: delta, oldEndPoint: oldEndPoint, textView: textView)
        let revision = pipeline.mutate { pipeline in
            pipeline.revision &+= 1
            if let edit {
                pipeline.edits.append(edit)
            }
            pipeline.text = snapshot
            return pipeline.revision
        }
        guard edit != nil else {
            completion(.failure(TreeSitterClientError.invalidEdit))
            return
        }

        let execAsync = Self.shouldExecuteAsync(
            editLength: range.length,
            delta: delta,
            documentLength: textView.documentRange.length
        )

        if !execAsync || forceSyncOperation {
            // Bounded, so an edit that re-lexes the rest of the document cannot hold the main thread: a parse that
            // does not finish in time is resumed by the background task below.
            let budget = forceSyncOperation ? nil : syncParseBudget
            let result = executor.execSync {
                applyEdits(revision: revision, budget: budget)
            }
            if case .success(.committed(let invalidatedRanges)) = result {
                DispatchQueue.dispatchMainIfNot { completion(.success(invalidatedRanges)) }
                return
            }
        }

        if !forceSyncOperation {
            // A keystroke supersedes the parse the one before it started. Its edit stays pending, so this parse
            // applies the burst at once.
            executor.cancelAll(below: .reset)
            executor.execAsync(
                priority: .edit,
                operation: { [weak self] in
                    guard let self else {
                        DispatchQueue.dispatchMainIfNot { completion(.success(IndexSet())) }
                        return true
                    }
                    guard case .committed(let invalidatedRanges) = self.applyEdits(revision: revision, budget: nil)
                    else { return false }
                    DispatchQueue.dispatchMainIfNot { completion(.success(invalidatedRanges)) }
                    return true
                },
                onCancel: {
                    DispatchQueue.dispatchMainIfNot {
                        completion(.failure(HighlightProvidingError.operationCancelled))
                    }
                }
            )
        }
    }

    /// Applies an edit to the main thread's copy of the text and returns it, to hand to a parse as its snapshot.
    ///
    /// Only the chunks the edit touches are rebuilt. When the copy does not match the storage, as after an edit that
    /// never reached this client, it is taken from the storage again.
    private func updatedText(textView: TextView, range: NSRange, delta: Int) -> TextSnapshot {
        Self.signposter.withIntervalSignpost("snapshot", "\(Self.threadName, privacy: .public)") {
            let storage = textView.textStorage.mutableString
            let replacement = NSRange(location: range.location, length: range.length + delta)
            if var text, range.max <= text.length, text.length + delta == storage.length, replacement.length >= 0,
               replacement.max <= storage.length {
                text.replace(range, with: storage, in: replacement)
                self.text = text
                return text
            }
            let text = TextSnapshot(string: storage)
            self.text = text
            return text
        }
    }

    /// Called before an edit is sent. We use this to set the ``oldEndPoint`` variable so tree-sitter knows where
    /// the document used to end.
    /// - Parameters:
    ///   - textView: The text view used.
    ///   - range: The range that will be edited.
    public func willApplyEdit(textView: TextView, range: NSRange) {
        oldEndPoint = textView.pointForLocation(range.max)
    }

    /// Initiates a highlight query.
    /// - Parameters:
    ///   - textView: The text view to use.
    ///   - range: The range to limit the highlights to.
    ///   - completion: Called when the query completes.
    public func queryHighlightsFor(
        textView: TextView,
        range: NSRange,
        completion: @escaping @MainActor (Result<[HighlightRange], Error>) -> Void
    ) {
        let operation = { [weak self] () -> [HighlightRange] in
            guard let self else { return [] }
            return Self.signposter.withIntervalSignpost(
                "queryHighlights",
                id: Self.signposter.makeSignpostID(),
                "\(Self.threadName, privacy: .public)"
            ) {
                self.queryHighlightsForRange(range: range).sorted { $0.range.location < $1.range.location }
            }
        }

        let longQuery = range.length > Constants.maxSyncQueryLength
        // For small highlight queries (typical per-keystroke chunks of 4096 chars),
        // run synchronously to avoid the async cancellation delay that causes
        // highlights to only appear after typing stops.
        let isSmallQuery = range.length <= 8_192
        let longDocument = !isSmallQuery && textView.documentRange.length > Constants.maxSyncContentLength
        let execAsync = longQuery || longDocument

        if !execAsync || forceSyncOperation {
            // Small queries attempt sync first. If the executor queue is
            // busy (e.g., pending large parse), fall through to async path.
            // This is thread-safe because execSync acquires the lock.
            let result = executor.execSync(operation)
            if case .success(let highlights) = result {
                DispatchQueue.dispatchMainIfNot { completion(.success(highlights)) }
                return
            }
        }

        if !forceSyncOperation {
            // The query reads the committed snapshot, not the text view, so it runs here and only its ranges go
            // to the main thread.
            executor.execAsync(
                priority: .access,
                operation: {
                    let highlights = operation()
                    DispatchQueue.dispatchMainIfNot { completion(.success(highlights)) }
                    return true
                },
                onCancel: {
                    DispatchQueue.dispatchMainIfNot {
                        completion(.failure(HighlightProvidingError.operationCancelled))
                    }
                }
            )
        }
    }
}
