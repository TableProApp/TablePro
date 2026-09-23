//
//  DatabaseTreeFilter.swift
//  TablePro
//

import Foundation
import TableProPluginKit

struct DatabaseTreeContainerKey: Hashable {
    let database: String
    let schema: String?
    let searchText: String
}

/// One filtered pass over a container's objects, split by kind. The container row needs the counts
/// and each group row under it needs one bucket, so both read this rather than filtering the whole
/// list again per group.
struct DatabaseTreeObjectBuckets {
    let tables: [SidebarObjectKind: [TableInfo]]
    let routines: [SidebarObjectKind: [RoutineInfo]]
    let triggers: [TriggerInfo]
    let userTypes: [UserDefinedTypeInfo]

    init(
        tables: [SidebarObjectKind: [TableInfo]],
        routines: [SidebarObjectKind: [RoutineInfo]],
        triggers: [TriggerInfo],
        userTypes: [UserDefinedTypeInfo] = []
    ) {
        self.tables = tables
        self.routines = routines
        self.triggers = triggers
        self.userTypes = userTypes
    }

    var isEmpty: Bool {
        tables.values.allSatisfy(\.isEmpty)
            && routines.values.allSatisfy(\.isEmpty)
            && triggers.isEmpty
            && userTypes.isEmpty
    }

    var itemCounts: [SidebarObjectKind: Int] {
        var counts = tables.mapValues(\.count)
        for (kind, list) in routines {
            counts[kind, default: 0] += list.count
        }
        counts[.trigger, default: 0] += triggers.count
        if !userTypes.isEmpty {
            counts[.type, default: 0] += userTypes.count
        }
        return counts
    }
}

enum DatabaseTreeFilter {
    static func matches(_ query: String, _ candidate: String) -> Bool {
        SidebarNameFilter.matches(query: query, candidate: candidate)
    }

    /// `database` is where the objects live when the caller knows it. A qualified search matches
    /// each object's own schema, and the database only when the search names one.
    static func filteredTables(_ tables: [TableInfo], searchText: String, database: String? = nil) -> [TableInfo] {
        let search = SidebarSearch(searchText)
        let admitted = tables.filter { search.matchesObject(named: $0.name, database: database, schema: $0.schema) }
        let matched = SidebarNameFilter.ranked(admitted, query: search.nameQuery, name: { $0.name })
        return deduplicated(matched, by: \.id)
    }

    static func filteredRoutines(
        _ routines: [RoutineInfo],
        searchText: String,
        database: String? = nil
    ) -> [RoutineInfo] {
        let search = SidebarSearch(searchText)
        let admitted = routines.filter { search.matchesObject(named: $0.name, database: database, schema: $0.schema) }
        let matched = SidebarNameFilter.ranked(admitted, query: search.nameQuery, name: { $0.name })
        return deduplicated(matched, by: \.id)
    }

    /// A trigger is findable by its own name and by the table it fires for, because a reader who
    /// knows only the table is exactly the reader the database-level list exists for.
    static func filteredTriggers(
        _ triggers: [TriggerInfo],
        searchText: String,
        database: String? = nil
    ) -> [TriggerInfo] {
        let search = SidebarSearch(searchText)
        let named = triggers.filter { search.matchesObject(named: $0.name, database: database, schema: $0.schema) }
        let matched = SidebarNameFilter.ranked(named, query: search.nameQuery, name: { $0.name })
        let byTable = search.nameQuery.isEmpty
            ? []
            : triggers.filter { trigger in
                guard let table = trigger.table else { return false }
                return search.matchesObject(named: table, database: database, schema: trigger.schema)
            }
        return deduplicated(matched + byTable, by: \.id)
    }

    static func filteredUserTypes(
        _ types: [UserDefinedTypeInfo],
        searchText: String,
        database: String? = nil
    ) -> [UserDefinedTypeInfo] {
        let search = SidebarSearch(searchText)
        let admitted = types.filter { search.matchesObject(named: $0.name, database: database, schema: $0.schema) }
        let matched = SidebarNameFilter.ranked(admitted, query: search.nameQuery, name: { $0.name })
        return deduplicated(matched, by: \.id)
    }

    static func objectBuckets(
        tables: [TableInfo],
        routines: [RoutineInfo],
        triggers: [TriggerInfo],
        userTypes: [UserDefinedTypeInfo] = [],
        searchText: String,
        database: String? = nil
    ) -> DatabaseTreeObjectBuckets {
        var tableBuckets: [SidebarObjectKind: [TableInfo]] = [:]
        for table in filteredTables(tables, searchText: searchText, database: database) {
            tableBuckets[SidebarObjectKind.resolve(tableType: table.type), default: []].append(table)
        }
        var routineBuckets: [SidebarObjectKind: [RoutineInfo]] = [:]
        for routine in filteredRoutines(routines, searchText: searchText, database: database) {
            routineBuckets[routine.kind.sidebarObjectKind, default: []].append(routine)
        }
        return DatabaseTreeObjectBuckets(
            tables: tableBuckets,
            routines: routineBuckets,
            triggers: filteredTriggers(triggers, searchText: searchText, database: database),
            userTypes: filteredUserTypes(userTypes, searchText: searchText, database: database)
        )
    }

    /// A schema whose objects have not loaded yet cannot be judged, so it stays visible. Reading an
    /// unloaded schema as an empty one hides it for the whole life of the filter and blanks the
    /// pane while the search-driven load is still running. A match on a procedure, trigger or type
    /// keeps the schema as surely as a match on a table.
    static func hierarchicalSchemaIsVisible(
        _ schema: String,
        searchText: String,
        isLoaded: Bool,
        tables: [TableInfo],
        routines: [RoutineInfo],
        triggers: [TriggerInfo],
        userTypes: [UserDefinedTypeInfo]
    ) -> Bool {
        let search = SidebarSearch(searchText)
        if search.matchesContainer(database: nil, schema: schema) { return true }
        guard isLoaded else { return search.admits(database: nil, schema: schema) }
        return !objectBuckets(
            tables: tables,
            routines: routines,
            triggers: triggers,
            userTypes: userTypes,
            searchText: searchText
        ).isEmpty
    }

    /// A schema the search matched by name shows everything inside it. Filtering its objects by the
    /// same query leaves the matched schema reporting no items.
    static func hierarchicalObjectBuckets(
        schema: String,
        tables: [TableInfo],
        routines: [RoutineInfo],
        triggers: [TriggerInfo],
        userTypes: [UserDefinedTypeInfo],
        searchText: String
    ) -> DatabaseTreeObjectBuckets {
        objectBuckets(
            tables: tables,
            routines: routines,
            triggers: triggers,
            userTypes: userTypes,
            searchText: SidebarSearch(searchText).matchesContainer(database: nil, schema: schema) ? "" : searchText
        )
    }

    /// `contentMatches` answers for what is inside a schema, and for a qualified search it has to
    /// apply the search's containers itself, as `schemaSearchVerdict` does.
    static func visibleSchemas(
        _ schemas: [String],
        systemSchemas: Set<String>,
        activeSchema: String?,
        showsSystem: Bool,
        searchText: String,
        database: String? = nil,
        contentMatches: (String) -> Bool
    ) -> [String] {
        let browsable = DatabaseTreeVisibility.visibleSchemas(
            schemas,
            systemSchemas: systemSchemas,
            activeSchema: activeSchema,
            showsSystem: showsSystem
        )
        let search = SidebarSearch(searchText)
        let matched = search.isEmpty
            ? browsable
            : browsable.filter { search.matchesContainer(database: database, schema: $0) || contentMatches($0) }
        return deduplicated(matched, by: { $0 })
    }

    /// What a search can say about one schema of a database-grouped tree. `unknown` is a schema
    /// whose objects neither the tree nor the all-schema listing can answer for yet, which stays on
    /// screen collapsed, for the reason `hierarchicalSchemaIsVisible` keeps an unloaded schema.
    enum SchemaSearchVerdict: Equatable {
        case match
        case noMatch
        case unknown

        var isVisible: Bool {
            self != .noMatch
        }
    }

    /// One pass over a database's all-schema listing, recording which schemas hold a match. A tree
    /// judges hundreds of schemas against the same listing, and scanning it once per schema cost a
    /// comparison per table per schema on every redraw.
    struct SchemaListingMatches: Equatable {
        let listed: Set<String>
        let matched: Set<String>
        let unlisted: Set<String>

        init(listing: CatalogTableListing.Result, database: String, searchText: String) {
            let search = SidebarSearch(searchText)
            var listed: Set<String> = []
            var matched: Set<String> = []
            for table in listing.tables {
                guard let schema = table.schema else { continue }
                listed.insert(schema)
                guard !matched.contains(schema),
                      search.matchesObject(named: table.name, database: database, schema: schema) else { continue }
                matched.insert(schema)
            }
            self.listed = listed
            self.matched = matched
            self.unlisted = listing.unlistedSchemas
        }
    }

    /// The schema's own loaded lists answer first. A schema the tree has not loaded is judged from
    /// the database's all-schema listing, and is unknown while that listing is missing, failed, or
    /// says it could not read the schema, unless a qualified search names another schema: holding
    /// every schema on screen for an object literally named with a dot is not worth it.
    ///
    /// `listingCoversSchema` is false for a schema the listing leaves out on purpose, a system
    /// schema, which is judged by its loaded lists alone, as every unloaded schema used to be.
    /// `countsSchemaName` is false where a schema that matches only by its own name would be
    /// noise, as in the flat list, which names a schema only for the objects found in it.
    static func schemaSearchVerdict(
        schema: String,
        database: String,
        searchText: String,
        loadedContent: DatabaseTreeObjectBuckets?,
        listingMatches: SchemaListingMatches?,
        listingCoversSchema: Bool = true,
        countsSchemaName: Bool = true
    ) -> SchemaSearchVerdict {
        let search = SidebarSearch(searchText)
        let namesContainer = search.qualified != nil || countsSchemaName
        if namesContainer, search.matchesContainer(database: database, schema: schema) { return .match }
        if let loadedContent { return loadedContent.isEmpty ? .noMatch : .match }
        guard listingCoversSchema else { return .noMatch }
        guard let listingMatches, !listingMatches.unlisted.contains(schema) else {
            return search.admits(database: database, schema: schema) ? .unknown : .noMatch
        }
        return listingMatches.matched.contains(schema) ? .match : .noMatch
    }

    /// A schema's objects as the tree has loaded them, filtered by the search. Nil until its tables
    /// are loaded, so a search can tell a schema holding no match from one nobody has listed yet.
    @MainActor
    static func loadedObjectBuckets(
        in service: DatabaseTreeMetadataService,
        connectionId: UUID,
        database: String,
        schema: String?,
        searchText: String
    ) -> DatabaseTreeObjectBuckets? {
        guard case .loaded(let tables) = service.tablesLoadState(
            connectionId: connectionId, database: database, schema: schema
        ) else { return nil }
        return objectBuckets(
            tables: tables,
            routines: service.routines(connectionId: connectionId, database: database, schema: schema),
            triggers: service.triggers(connectionId: connectionId, database: database, schema: schema),
            userTypes: service.userDefinedTypes(connectionId: connectionId, database: database, schema: schema),
            searchText: searchText,
            database: database
        )
    }

    /// The schemas besides the browsed one that a search found objects in, which the flat list adds
    /// below its own sections. Only confirmed matches are named: a flat list that also named every
    /// schema whose listing had not arrived would read as a list of results.
    static func otherSchemaMatches(
        database: String,
        browsedSchema: String?,
        searchText: String,
        hiddenSchemas: Set<String>,
        allSchemaTables: MetadataLoadState<CatalogTableListing.Result>,
        loadedContent: (String) -> DatabaseTreeObjectBuckets?
    ) -> [String] {
        guard !SidebarSearch(searchText).isEmpty, let listing = allSchemaTables.value else { return [] }
        let listingMatches = SchemaListingMatches(listing: listing, database: database, searchText: searchText)
        return listingMatches.listed
            .filter { schema in
                guard schema != browsedSchema, !hiddenSchemas.contains(schema) else { return false }
                return schemaSearchVerdict(
                    schema: schema,
                    database: database,
                    searchText: searchText,
                    loadedContent: loadedContent(schema),
                    listingMatches: listingMatches,
                    countsSchemaName: false
                ) == .match
            }
            .sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }

    private static func deduplicated<Element, Key: Hashable>(
        _ items: [Element],
        by key: (Element) -> Key
    ) -> [Element] {
        var seen = Set<Key>()
        return items.filter { seen.insert(key($0)).inserted }
    }
}
