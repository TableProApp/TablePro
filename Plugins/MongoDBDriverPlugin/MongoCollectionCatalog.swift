//
//  MongoCollectionCatalog.swift
//  MongoDBDriverPlugin
//

import Foundation

/// What `listCollections` says about one collection, read from its canonical Extended JSON.
///
/// The validator is kept as the exact text the server sent, because it is written back verbatim: in
/// a `collMod` when a rename has to carry it along, and in the aggregation that tries the change
/// against it before anything is written.
struct MongoCollectionInfo: Equatable, Sendable {
    enum Kind: Equatable, Sendable {
        case missing
        case collection
        case view
        case timeseries
        case other(String)
    }

    let name: String
    let kind: Kind
    let validatorJson: String?
    let validationLevel: String
    let validationAction: String
    let encryptedFieldPaths: [String]
    let isCapped: Bool

    /// Filters `listCollections` to one name, exactly, which `db.getCollectionInfos` in the shell
    /// does not do.
    static func filterJson(for collection: String) -> String {
        "{\"name\": \(MongoScriptJson.jsonString(collection))}"
    }

    static let viewFilterJson = "{\"type\": \"view\"}"

    init(collection: String, infoJson: String?) {
        self.name = collection
        guard let infoJson else {
            self.kind = .missing
            self.validatorJson = nil
            self.validationLevel = "strict"
            self.validationAction = "error"
            self.encryptedFieldPaths = []
            self.isCapped = false
            return
        }
        let options = MongoScriptJson.member(of: infoJson, key: "options")
        let type = MongoScriptJson.member(of: infoJson, key: "type").flatMap(MongoJsonValue.parse) as? String
        self.kind = Self.kind(of: type ?? "collection")
        self.validatorJson = options.flatMap { Self.nonEmptyDocument(MongoScriptJson.member(of: $0, key: "validator")) }
        self.validationLevel = options.flatMap { Self.string(MongoScriptJson.member(of: $0, key: "validationLevel")) }
            ?? "strict"
        self.validationAction = options.flatMap { Self.string(MongoScriptJson.member(of: $0, key: "validationAction")) }
            ?? "error"
        self.encryptedFieldPaths = options.map(Self.encryptedFieldPaths(in:)) ?? []
        self.isCapped = options.flatMap { Self.bool(MongoScriptJson.member(of: $0, key: "capped")) } ?? false
    }

    /// Whether the server checks a changed document against the validator and refuses the write
    /// when it fails. `warn` only logs, and `off` checks nothing.
    var enforcesValidator: Bool {
        validatorJson != nil && validationLevel != "off" && validationAction != "warn"
    }

    var validatesOnlyValidDocuments: Bool { validationLevel == "moderate" }

    private static func kind(of type: String) -> Kind {
        switch type {
        case "collection": return .collection
        case "view": return .view
        case "timeseries": return .timeseries
        default: return .other(type)
        }
    }

    private static func string(_ json: String?) -> String? {
        json.flatMap(MongoJsonValue.parse) as? String
    }

    private static func bool(_ json: String?) -> Bool? {
        json.flatMap(MongoJsonValue.parse) as? Bool
    }

    private static func nonEmptyDocument(_ json: String?) -> String? {
        guard let json, let object = MongoJsonValue.parse(json) as? [String: Any], !object.isEmpty else { return nil }
        return json
    }

    private static func encryptedFieldPaths(in optionsJson: String) -> [String] {
        guard let options = MongoJsonValue.parse(optionsJson) as? [String: Any],
              let encrypted = options["encryptedFields"] as? [String: Any],
              let fields = encrypted["fields"] as? [[String: Any]] else { return [] }
        return fields.compactMap { $0["path"] as? String }
    }
}

struct MongoIndexSpec {
    let name: String
    let spec: [String: Any]

    init?(json: String) {
        guard let spec = MongoJsonValue.parse(json) as? [String: Any] else { return nil }
        self.name = spec["name"] as? String ?? ""
        self.spec = spec
    }

    func reaches(_ field: String) -> Bool {
        MongoIndexFieldReferences.reaches(spec, field: field)
    }
}

/// An Atlas Search or Vector Search index as `$listSearchIndexes` lists it. `listIndexes` never
/// returns one, because `mongot` holds them, so a rename that checked `listIndexes` alone left a
/// search index pointing at a path no document has.
struct MongoSearchIndex {
    static let listingPipelineJson = "[{\"$listSearchIndexes\": {}}]"

    /// Asked of a server that does not know `$listSearchIndexes`, to learn whether it runs search at
    /// all. An answer, empty or not, means it does.
    static let searchProbePipelineJson = "[{\"$search\": {\"exists\": {\"path\": \"_id\"}}}, {\"$limit\": 1}]"

    /// What a server with no search answers every search stage with, `$listSearchIndexes` and
    /// `$search` alike, so it has no search index to break. Measured: 6047401, "stage is only allowed
    /// on MongoDB Atlas", on 6.0.28 and 7.0.43 community, and 31082 SearchNotEnabled, "requires
    /// additional configuration", on 8.2.12 community with no `mongot` configured.
    static let noSearchErrorCodes: Set<UInt32> = [6_047_401, 31_082]

    /// "Unrecognized pipeline stage name", what a server older than `$listSearchIndexes` answers.
    /// That alone says nothing about search: an Atlas cluster that predates the stage runs `$search`
    /// and holds search indexes it cannot list. Measured on 5.0.33 community, which answers it for
    /// `$search` too.
    static let unknownStageErrorCode: UInt32 = 40_324

    enum ListingFailure: Equatable {
        /// The server has no search, so the collection has no search index.
        case serverWithoutSearch
        /// The server predates the listing stage. Whether it has search is asked of `$search`.
        case listingStageUnknown
        /// The indexes are unknown, and the save stops.
        case unknown
    }

    static func listingFailure(code: UInt32) -> ListingFailure {
        if noSearchErrorCodes.contains(code) { return .serverWithoutSearch }
        return code == unknownStageErrorCode ? .listingStageUnknown : .unknown
    }

    /// Whether the server's answer to `searchProbePipelineJson` shows it has no search: it does not
    /// know the stage either, or refuses it the way a server without search does. Nil is an answer.
    static func searchIsUnavailable(probeErrorCode: UInt32?) -> Bool {
        guard let probeErrorCode else { return false }
        return listingFailure(code: probeErrorCode) != .unknown
    }

    /// Why a save stops on a server that runs search and cannot list its search indexes.
    static var unlistableIndexesReason: String {
        String(
            localized: """
                This server runs Atlas Search but cannot list its search indexes, so one that uses the field cannot be \
                ruled out. Check the collection's search indexes in Atlas, then change the field from a query tab.
                """
        )
    }

    let name: String
    let definitions: [Any]

    init?(json: String) {
        guard let listing = MongoJsonValue.parse(json) as? [String: Any] else { return nil }
        self.name = listing["name"] as? String ?? ""
        self.definitions = Self.definitions(in: listing)
    }

    /// Whether any definition of the index names the field, the one being built included.
    func mentions(_ field: String) -> Bool {
        definitions.contains { MongoSearchDefinitionFieldReferences.reaches($0, field: field) }
    }

    /// `latestDefinition` is the newest, and every `mongot` reports the definition it serves from
    /// and the one it is building under `statusDetail`, which can still be an older one.
    private static func definitions(in value: Any) -> [Any] {
        if let list = value as? [Any] {
            return list.flatMap(definitions(in:))
        }
        guard let object = value as? [String: Any] else { return [] }
        return object.flatMap { key, member -> [Any] in
            key == "latestDefinition" || key == "definition" ? [member] : definitions(in: member)
        }
    }
}

/// A view as `listCollections` describes it: the collection or view it reads, and its pipeline.
struct MongoViewDefinition {
    let name: String
    let viewOn: String
    let pipeline: [Any]

    init?(json: String) {
        guard let info = MongoJsonValue.parse(json) as? [String: Any],
              let name = info["name"] as? String,
              let options = info["options"] as? [String: Any],
              let viewOn = options["viewOn"] as? String else { return nil }
        self.name = name
        self.viewOn = viewOn
        self.pipeline = options["pipeline"] as? [Any] ?? []
    }

    init(name: String, viewOn: String, pipeline: [Any]) {
        self.name = name
        self.viewOn = viewOn
        self.pipeline = pipeline
    }

    /// Every view whose output depends on the collection: those defined on it, those defined on
    /// such a view, and those that join or union it from any stage, at any depth. Taken to a fixed
    /// point, so the order `listCollections` lists views in does not matter.
    static func dependents(of collection: String, among views: [MongoViewDefinition]) -> [MongoViewDefinition] {
        var reached: Set<String> = [collection]
        var dependents: [MongoViewDefinition] = []
        var grew = true
        while grew {
            grew = false
            for view in views where !reached.contains(view.name) && view.reads(anyOf: reached) {
                reached.insert(view.name)
                dependents.append(view)
                grew = true
            }
        }
        return dependents
    }

    func reads(anyOf sources: Set<String>) -> Bool {
        sources.contains(viewOn) || Self.joins(pipeline, anyOf: sources)
    }

    func readsField(_ field: String) -> Bool {
        MongoPipelineFieldReferences.pipelineReads(pipeline, field: field)
    }

    private static func joins(_ value: Any, anyOf sources: Set<String>) -> Bool {
        if let list = value as? [Any] {
            return list.contains { joins($0, anyOf: sources) }
        }
        guard let object = value as? [String: Any] else { return false }
        for (key, member) in object {
            if key == "$lookup" || key == "$graphLookup",
               let spec = member as? [String: Any], namesSource(spec["from"], in: sources) {
                return true
            }
            if key == "$unionWith", namesSource(member, in: sources) || namesSource((member as? [String: Any])?["coll"], in: sources) {
                return true
            }
            if joins(member, anyOf: sources) { return true }
        }
        return false
    }

    private static func namesSource(_ value: Any?, in sources: Set<String>) -> Bool {
        if let name = value as? String { return sources.contains(name) }
        if let spec = value as? [String: Any], let name = spec["coll"] as? String { return sources.contains(name) }
        return false
    }
}

/// How the driver keys what it learned about a collection's documents: by database and collection,
/// because two databases can hold a collection of the same name with different field types. Neither
/// name can hold a NUL, so the one in the key separates them.
enum MongoCollectionCacheKey {
    static func key(database: String, collection: String) -> String {
        "\(database)\u{0}\(collection)"
    }

    static func names(_ key: String, collection: String) -> Bool {
        key.hasSuffix("\u{0}\(collection)")
    }
}
