import Foundation

/// libbson's answers the edit needs, passed in so the decisions can be made without a connection.
protocol MongoDocumentCodec: Sendable {
    /// Whether `text` reads as exactly the document `canonical` holds, byte for byte in BSON.
    func isSameDocument(_ text: String, asCanonical canonical: String) -> Bool

    /// The BSON size of a document written as Extended JSON, or nil when libbson cannot read it.
    func bsonSize(of json: String) -> Int?
}

/// A document the server returned for a locator, as canonical Extended JSON.
///
/// `isRepresentable` is libbson's own answer to whether that text reads back as the same BSON. The
/// text alone cannot say: a stored subdocument `{"$numberInt": "5"}` prints and rereads as identical
/// text, and rereads as an int, and every NaN prints as `"NaN"` whatever payload it carries.
struct MongoStoredDocument: Equatable, Sendable {
    let canonical: String
    let isRepresentable: Bool
}

/// The documents a read finds that are, byte for byte, the one a locator names.
///
/// The read runs under the collection's collation, so it can also find documents whose `_id` only
/// collates or compares equal. One server holds at most one of those, because the `_id` index takes
/// the collection's collation (measured on 7.0: `"ABC"` beside `"abc"` is a duplicate key under
/// strength 2, and so is `NumberLong(1)` beside `1`). A sharded collection enforces that per shard, so
/// every shard can answer with one, and a read that stopped at a count would stop on them. The read
/// goes on until it has two exact matches, which is all the ambiguity check needs.
struct MongoExactMatches {
    let identity: MongoDocumentIdentity
    private(set) var documents: [MongoStoredDocument] = []

    init(identity: MongoDocumentIdentity) {
        self.identity = identity
    }

    var isDecided: Bool {
        documents.count > 1
    }

    /// `isRepresentable` is asked only of an exact match, since it reads the whole document again.
    mutating func consider(_ canonical: String, isRepresentable: () -> Bool) {
        guard !isDecided, identity.identifies(canonical) else { return }
        documents.append(MongoStoredDocument(canonical: canonical, isRepresentable: isRepresentable()))
    }
}

/// Opens a stored document as the text Edit Document shows, or says why it cannot be edited.
enum MongoEditableDocument {
    /// A write command may be 16 MB plus room for the command around it, and the guarded replace
    /// carries the stored document, its signature and the replacement.
    static let commandSizeLimit = 16 * 1_024 * 1_024

    /// Nil when no stored document has the locator any more.
    ///
    /// The guard is built before anything else is asked, so a value it refuses is named as that
    /// value: a NaN libbson cannot write back is refused for being a NaN, not for its payload.
    static func text(
        for identity: MongoDocumentIdentity,
        among stored: [MongoStoredDocument],
        codec: MongoDocumentCodec
    ) throws -> String? {
        let matches = stored.filter { identity.identifies($0.canonical) }
        guard let match = matches.first else { return nil }
        guard matches.count == 1 else { throw MongoDBDocumentEditingError.ambiguousIdentity }

        let document = try MongoDocumentText(parsing: match.canonical)
        let filter = try MongoDocumentGuard.filter(for: document)
        guard match.isRepresentable else { throw MongoDBDocumentEditingError.inexactAsText }
        if let field = MongoDocumentReplacement.emptyTimestampField(in: document) {
            throw MongoDBDocumentEditingError.emptyTimestamp(field)
        }
        try checkFits(filter: filter, canonical: match.canonical, codec: codec)

        let readable = MongoDocumentPresentation.editableText(document)
        guard codec.isSameDocument(readable, asCanonical: match.canonical) else {
            return MongoDocumentPresentation.prettyCanonical(document)
        }
        return readable
    }

    /// The steps that read a document for editing: the server's version, what kind of namespace the
    /// collection is, then the stored documents.
    ///
    /// They run as one call on the connection, because a call clears the connection's cancellation
    /// latch as it starts and a cancel that lands during one step has to stop the next: the latch is
    /// cleared once and asked before every step. A user who may read the collection but not list
    /// collections is not stopped here; the server's own answer arrives at Save instead.
    static func readStored(
        serverVersion: () -> String?,
        listCollectionsReply: () throws -> [String: Any]?,
        storedDocuments: () throws -> [MongoStoredDocument],
        checkCancelled: () throws -> Void
    ) throws -> [MongoStoredDocument] {
        try checkCancelled()
        guard MongoDBCapabilities.parse(serverVersion()).supportsDocumentReplaceGuard else {
            throw MongoDBDocumentEditingError.serverTooOld
        }
        try checkCancelled()
        if let refusal = try namespaceRefusal(listCollectionsReply) { throw refusal }
        try checkCancelled()
        return try storedDocuments()
    }

    private static func namespaceRefusal(
        _ listCollectionsReply: () throws -> [String: Any]?
    ) throws -> MongoDBDocumentEditingError? {
        do {
            guard let reply = try listCollectionsReply() else { return nil }
            return namespaceRefusal(listCollectionsReply: reply)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            return nil
        }
    }

    /// No `limit`, because the documents the collation also finds would count towards it; see
    /// `MongoExactMatches`.
    static func readOptions(maxTimeMS: Int32?) -> String {
        guard let maxTimeMS else { return "{}" }
        return #"{"maxTimeMS":\#(maxTimeMS)}"#
    }

    /// The `listCollections` command that says what kind of namespace a name is.
    static func namespaceTypeCommand(for collection: String) -> String {
        #"{"listCollections":1,"filter":{"name":\#(MongoDocumentText.quoted(collection))}}"#
    }

    /// Only a plain collection replaces a document found by its `_id`. A view refuses every write,
    /// and a time-series collection refuses a replace (code 72 on 7.0) and does not keep `_id` unique,
    /// so each is refused when the document opens rather than after it was edited. A kind this does
    /// not know is refused too. A reply that names no kind is let through, and the server's own
    /// answer arrives at Save.
    static func namespaceRefusal(listCollectionsReply reply: [String: Any]) -> MongoDBDocumentEditingError? {
        guard let cursor = reply["cursor"] as? [String: Any],
              let batch = cursor["firstBatch"] as? [[String: Any]],
              let type = batch.first?["type"] as? String else { return nil }
        switch type {
        case "collection":
            return nil
        case "view":
            return .view
        case "timeseries":
            return .timeSeries
        default:
            return .notACollection(type)
        }
    }

    /// Checked when the document opens rather than when it is saved, so nobody edits a document
    /// that could never be written back.
    static func checkFits(filter: String, canonical: String, codec: MongoDocumentCodec) throws {
        guard let filterSize = codec.bsonSize(of: filter) else { throw MongoDocumentGuard.Refusal.tooDeep }
        let documentSize = codec.bsonSize(of: canonical) ?? 0
        guard filterSize + documentSize <= commandSizeLimit else { throw MongoDBDocumentEditingError.tooLarge }
    }
}
