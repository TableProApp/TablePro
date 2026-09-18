import Foundation

/// A cursor the script holds but the server has not been asked about yet.
///
/// `find()` in mongosh returns without touching the server, and the modifiers chained onto it are
/// part of the query rather than post-processing. Keeping the cursor lazy is what makes
/// `.sort().limit()` reach MongoDB as one query, and it is also what lets a statement whose value
/// is a cursor skip JavaScript entirely: nothing has been marshalled yet, so the driver can drain
/// it straight into the result grid.
final class MongoScriptCursor {
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
        let batch = try materialise(loader: loader)
        guard position < batch.json.count else {
            return MongoScriptDocumentBatch(json: [], isTruncated: batch.isTruncated)
        }
        let rest = Array(batch.json[position...])
        position = batch.json.count
        return MongoScriptDocumentBatch(json: rest, isTruncated: batch.isTruncated)
    }

    func page(
        size: Int,
        loader: (MongoScriptCursor) throws -> MongoScriptDocumentBatch
    ) throws -> (batch: MongoScriptDocumentBatch, done: Bool) {
        let batch = try materialise(loader: loader)
        guard position < batch.json.count else {
            return (MongoScriptDocumentBatch(json: [], isTruncated: batch.isTruncated), true)
        }
        let end = min(position + max(size, 1), batch.json.count)
        let slice = Array(batch.json[position ..< end])
        position = end
        return (
            MongoScriptDocumentBatch(json: slice, isTruncated: batch.isTruncated),
            position >= batch.json.count
        )
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
final class MongoScriptCursorRegistry {
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
