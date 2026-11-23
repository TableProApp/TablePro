import Foundation

/// A cursor the script holds but the server has not been asked about yet.
///
/// `find()` in mongosh returns without touching the server, and the modifiers chained onto it are
/// part of the query rather than post-processing. Keeping the cursor lazy is what makes
/// `.sort().limit()` reach MongoDB as one query, and it is also what lets a statement whose value
/// is a cursor skip JavaScript entirely: nothing has been marshalled yet, so the driver can drain
/// it straight into the result grid.
nonisolated final class MongoScriptCursor {
    enum Kind {
        case find(filter: String)
        case aggregate(pipeline: String)
    }

    let handle: Int
    let kind: Kind
    let database: String
    let collection: String
    private(set) var options: MongoScriptCursorOptions
    private(set) var isStarted = false
    private(set) var isClosed = false

    private var materialised: MongoScriptDocumentBatch?
    private var position = 0
    // The drained read's `isTruncated`, set once every document has been handed out. The host keeps up to 64 cursors
    // a connection, so a drained one lets go of its documents' text and answers from this alone.
    private var drainedIsTruncated: Bool?

    init(
        handle: Int,
        kind: Kind,
        database: String,
        collection: String,
        options: MongoScriptCursorOptions = .none
    ) {
        self.handle = handle
        self.kind = kind
        self.database = database
        self.collection = collection
        self.options = options
    }

    var isFind: Bool {
        if case .find = kind { return true }
        return false
    }

    /// A find with no projection returns documents exactly as they are stored.
    var returnsWholeDocuments: Bool {
        isFind && options.projection == nil
    }

    var filterJson: String {
        if case .find(let filter) = kind { return filter }
        return "{}"
    }

    var pipelineJson: String {
        if case .aggregate(let pipeline) = kind { return pipeline }
        return "[]"
    }

    func configure(key: String, value: String) throws {
        guard !isStarted else {
            throw MongoScriptError(MongoScriptText.cursorAlreadyStarted(key))
        }
        try options.apply(key: key, value: value)
    }

    /// Documents the script has not consumed yet, materialising on the first ask.
    func remaining(loader: (MongoScriptCursor) throws -> MongoScriptDocumentBatch) throws -> MongoScriptDocumentBatch {
        if let drainedIsTruncated { return MongoScriptDocumentBatch(json: [], isTruncated: drainedIsTruncated) }
        let batch = try materialise(loader: loader)
        let rest = position < batch.json.count ? Array(batch.json[position...]) : []
        markExhausted(batch)
        return MongoScriptDocumentBatch(json: rest, isTruncated: batch.isTruncated)
    }

    func page(
        size: Int,
        loader: (MongoScriptCursor) throws -> MongoScriptDocumentBatch
    ) throws -> (batch: MongoScriptDocumentBatch, done: Bool) {
        if let drainedIsTruncated { return (MongoScriptDocumentBatch(json: [], isTruncated: drainedIsTruncated), true) }
        let batch = try materialise(loader: loader)
        let end = min(position + max(size, 1), batch.json.count)
        let slice = position < end ? Array(batch.json[position ..< end]) : []
        position = end
        let done = position >= batch.json.count
        if done { markExhausted(batch) }
        return (MongoScriptDocumentBatch(json: slice, isTruncated: batch.isTruncated), done)
    }

    private func markExhausted(_ batch: MongoScriptDocumentBatch) {
        drainedIsTruncated = batch.isTruncated
        materialised = nil
        position = 0
    }

    func close() {
        isClosed = true
        materialised = nil
    }

    private func materialise(
        loader: (MongoScriptCursor) throws -> MongoScriptDocumentBatch
    ) throws -> MongoScriptDocumentBatch {
        if let materialised { return materialised }
        isStarted = true
        let batch = try loader(self)
        materialised = batch
        return batch
    }
}

/// The cursors one script run has open, keyed by the handle JavaScript holds.
nonisolated final class MongoScriptCursorRegistry {
    private var cursors: [Int: MongoScriptCursor] = [:]
    private var nextHandle = 1

    func open(
        kind: MongoScriptCursor.Kind,
        database: String,
        collection: String,
        options: MongoScriptCursorOptions = .none
    ) -> MongoScriptCursor {
        let cursor = MongoScriptCursor(
            handle: nextHandle, kind: kind, database: database, collection: collection, options: options
        )
        cursors[nextHandle] = cursor
        nextHandle += 1
        return cursor
    }

    func cursor(for handle: Int) throws -> MongoScriptCursor {
        guard let cursor = cursors[handle], !cursor.isClosed else {
            throw MongoScriptError(MongoScriptText.unknownCursor)
        }
        return cursor
    }

    func close(handle: Int) {
        cursors[handle]?.close()
        cursors[handle] = nil
    }

    /// Drops all but the most recent cursors.
    ///
    /// A cursor outlives the statement that opened it, because a shell lets you keep one in a
    /// variable and read it in the next statement. Without a ceiling that would hold every
    /// materialised page for the life of the connection, so the oldest go first.
    func prune(keeping limit: Int) {
        guard cursors.count > limit else { return }
        for handle in cursors.keys.sorted().dropLast(limit) {
            cursors[handle]?.close()
            cursors[handle] = nil
        }
    }

    func removeAll() {
        for cursor in cursors.values { cursor.close() }
        cursors.removeAll()
    }
}
