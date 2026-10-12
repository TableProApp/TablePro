import Foundation

public struct FirestoreDocument: Sendable, Equatable {
    /// Relative to `.../documents`, such as `users/alice`.
    public let path: String
    public let fields: [String: FirestoreValue]
    public let updateTime: String?

    public init(path: String, fields: [String: FirestoreValue], updateTime: String? = nil) {
        self.path = path
        self.fields = fields
        self.updateTime = updateTime
    }

    public init(rest json: FirebaseJSON, documentRoot: String) throws {
        guard let name = json["name"]?.stringValue else {
            throw FirebaseError.malformedResponse(String(localized: "Firestore sent a document with no name."))
        }
        let fields = json["fields"]?.objectValue ?? [:]
        self.path = FirestorePath.relative(name, documentRoot: documentRoot)
        self.fields = try fields.mapValues { try FirestoreValue(rest: $0, documentRoot: documentRoot) }
        self.updateTime = json["updateTime"]?.stringValue
    }

    public func restFields(documentRoot: String) -> FirebaseJSON {
        .object(fields.mapValues { $0.rest(documentRoot: documentRoot) })
    }
}

/// A page of documents laid out as grid rows: `__name__` first, then every field any document on
/// the page has, in name order. A field a document lacks is reported absent, not null.
public struct FirestoreRowSet: Sendable, Equatable {
    public let columns: [String]
    public let columnTypes: [String]
    public let rows: [[FirestoreCell.Display]]
    public let locators: [String]
    public let absentCells: [Int: Set<Int>]
    /// The type each document's fields hold, keyed by document path, so an edit is typed by the
    /// value it replaces rather than by the column's majority.
    public let cellTypes: [String: [String: String]]

    public init(documents: [FirestoreDocument], target: FirestoreCollectionTarget) {
        let fieldNames = Set(documents.flatMap { $0.fields.keys }).sorted()
        let columns = [FirestoreQueryBuilder.nameField] + fieldNames
        var rows: [[FirestoreCell.Display]] = []
        var absent: [Int: Set<Int>] = [:]
        var cellTypes: [String: [String: String]] = [:]
        rows.reserveCapacity(documents.count)
        for (rowIndex, document) in documents.enumerated() {
            var row: [FirestoreCell.Display] = [.text(target.rowName(forDocumentPath: document.path))]
            for (offset, name) in fieldNames.enumerated() {
                if let value = document.fields[name] {
                    row.append(FirestoreCell.display(value))
                } else {
                    row.append(.null)
                    absent[rowIndex, default: []].insert(offset + 1)
                }
            }
            rows.append(row)
            cellTypes[document.path] = document.fields.mapValues(\.typeName)
        }
        self.columns = columns
        self.columnTypes = [FirestoreTypeName.string] + fieldNames.map { name in
            FirestoreCell.dominantType(documents.map { $0.fields[name] })
        }
        self.rows = rows
        self.locators = documents.map(\.path)
        self.absentCells = absent
        self.cellTypes = cellTypes
    }
}
