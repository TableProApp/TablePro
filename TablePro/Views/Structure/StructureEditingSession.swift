//
//  StructureEditingSession.swift
//  TablePro
//

import Combine
import Foundation
import os
import TableProPluginKit

/// Everything one tab's structure editor is, held outside the view that presents it.
///
/// `MainEditorContentView` builds only the selected tab's content, and the results view mode is a
/// `switch` inside that, so switching tabs and switching a tab between Data and Structure both tear
/// the view down and take its `@State` with it. The user's staged ALTERs, where they were in the
/// editor, and the ability to apply them all have to outlive that.
///
/// Two rules follow, and both were learned the hard way.
///
/// First, **the session is the tab's editor, not a cache the view consults.** Anything seeded from
/// the session into `@State` is frozen at the moment SwiftUI first creates that view identity, so it
/// silently keeps answering for whichever tab got there first. `TableStructureView` therefore holds
/// no editor state of its own; it reads and writes this object.
///
/// Second, **applying the staged edits cannot require a mounted view.** The close prompt asks about
/// staged ALTERs by reading this session, so a background tab can raise it; if Save then dispatched
/// through the view, it would save nothing and the close would destroy the work anyway.
/// `applyStagedChanges` lives here for that reason.
///
/// The loaded schema travels with the edits, and not as an optimisation. `StructureChangeManager`
/// adopts a new baseline through `loadSchema`, which clears every pending change, the validation
/// errors and the undo stack, so a rebuild that refetched the schema would discard the edits on its
/// way back in. Holding the baseline here is what lets the rebuild skip the fetch, and skipping the
/// fetch is the only version of this that keeps the edits.
@MainActor
internal final class StructureEditingSession: ObservableObject {
    private static let logger = Logger(subsystem: "com.TablePro", category: "StructureEditingSession")

    /// The scope and table this session was opened against. A tab retargeted to another table gets
    /// a new session rather than inheriting edits staged against the old one.
    internal let identity: String

    internal let connection: DatabaseConnection
    internal let databaseName: String
    internal let schemaName: String?
    internal let tableName: String

    /// What kind of object this session edits, which decides which edits it may offer at all. A tab
    /// retargeted to another object gets a new session, so this never has to change under a session.
    internal let objectKind: TableInfo.TableType

    internal let changeManager = StructureChangeManager()

    /// Built here, not seeded into the view's `@State`. `State(wrappedValue:)` runs only the first
    /// time SwiftUI creates a given view identity, and `StructureGridDelegate` holds its change
    /// manager in a `let`, so a delegate seeded from a session went on writing into that session
    /// after the view had been handed a different one. Owning both here means the grid the user
    /// types into and the edits the close prompt reports are the same object by construction.
    internal let gridDelegate: StructureGridDelegate
    internal let wrappedChangeManager: AnyChangeManager

    internal var scope: DatabaseScope {
        DatabaseScope(connectionId: connection.id, database: databaseName, schema: schemaName)
    }

    @Published internal var columns: [ColumnInfo] = []
    @Published internal var indexes: [IndexInfo] = []
    @Published internal var foreignKeys: [ForeignKeyInfo] = []
    @Published internal var checkConstraints: [CheckConstraintInfo] = []
    @Published internal var triggers: [TriggerInfo] = []
    @Published internal var ddlStatement: String = ""
    @Published internal var tabData = StructureTabDataState()

    @Published internal var concurrentRefresh: MetadataLoadState<PluginConcurrentRefreshAvailability?> = .idle
    private var concurrentRefreshRequest = 0

    /// Where the user was. Held here rather than in the view because two tabs on one table are two
    /// editors: one being on Indexes must not move the other, and neither should lose its place to
    /// a trip through the Data view.
    @Published internal var selectedTab: StructureTab = .columns
    @Published internal var searchText = ""
    @Published internal var sortState = SortState()
    @Published internal var sortDescriptor: StructureSortDescriptor?
    @Published internal var columnLayouts: [StructureTab: ColumnLayoutState] = [:]

    /// A tab the server withdraws cannot stay selected, or the editor shows a grid for something
    /// the server has none of and no segment matches the selection.
    @Published internal var serverSupport = StructureServerSupport.unrestricted {
        didSet {
            guard !availableTabs.contains(selectedTab) else { return }
            selectedTab = .columns
        }
    }

    internal var availableTabs: [StructureTab] {
        StructureTabAvailability.tabs(for: connection.type, serverSupport: serverSupport)
    }

    /// What a mount fetches: the sub-tabs the change manager is baselined from, then the one the
    /// user left selected. A mount does not change the selection, so nothing else fetches that one,
    /// and after `markStructureStale` or an apply it would go on showing the object as it was.
    internal var tabsFetchedOnMount: [StructureTab] {
        var tabs: [StructureTab] = [.columns, .indexes, .foreignKeys]
        if availableTabs.contains(.checkConstraints) {
            tabs.append(.checkConstraints)
        }
        if !tabs.contains(selectedTab) {
            tabs.append(selectedTab)
        }
        return tabs
    }

    /// What the bottom bar offers while this tab is showing its structure.
    ///
    /// Keyed by tab through the session, so two structure tabs cannot answer for each other. The
    /// shape this replaces was one app-wide object with a `currentOwner` guard, and the guard
    /// existed only to work out which structure view the buttons currently belonged to.
    @Published internal var footer = StructureFooterCapability()

    /// Whether the opening fetch has already run. True only after a real load, so a rebuild adopts
    /// what is here instead of refetching, while a genuine refresh still goes through
    /// `onRefreshData`, which asks before discarding.
    @Published internal var hasLoaded = false

    /// Bumped when `applyStagedChanges` has written to the database. A mounted view watches it and
    /// refreshes what it is showing; an unmounted one does not need to, because the apply already
    /// marked the tab data stale and cleared `hasLoaded`.
    @Published internal private(set) var appliedVersion = 0

    /// Raised across a save so the `onChange` handlers watching `columns`, `indexes` and
    /// `foreignKeys` do not mistake the post-save reload for the user editing.
    @Published internal var isApplying = false

    /// When the last apply landed, used to keep an incoming refresh notification from re-fetching
    /// what the save has just re-fetched.
    @Published internal var lastAppliedAt: Date?

    internal init(
        identity: String,
        connection: DatabaseConnection,
        databaseName: String,
        schemaName: String?,
        tableName: String,
        objectKind: TableInfo.TableType = .table,
        serverSupport: StructureServerSupport = .unrestricted
    ) {
        self.identity = identity
        self.connection = connection
        self.databaseName = databaseName
        self.schemaName = schemaName
        self.tableName = tableName
        self.objectKind = objectKind
        self.serverSupport = serverSupport
        gridDelegate = StructureGridDelegate(
            structureChangeManager: changeManager,
            selectedTab: .columns,
            connection: connection,
            tableName: tableName,
            objectKind: objectKind,
            coordinator: nil
        )
        gridDelegate.referenceMenus.schemaName = schemaName
        wrappedChangeManager = AnyChangeManager(changeManager)
    }

    internal func markApplied() {
        appliedVersion += 1
    }

    /// A change made elsewhere while edits were staged here. Fetching it would re-baseline the change
    /// manager and discard the edits without asking, so it waits for them to go. An apply fetches
    /// everything again, which answers it; an undo or a discard leaves it to `settleOwedRefetch`.
    internal private(set) var owesRefetch = false

    /// The object changed outside this editor, so the next mount fetches it again. A session holding
    /// staged edits keeps them and the baseline they were made against, and owes the fetch instead.
    internal func markStructureStale() {
        guard !changeManager.hasChanges else {
            owesRefetch = true
            return
        }
        markEveryTabStale()
        hasLoaded = false
    }

    /// Answers a change owed from while edits were staged, once they are gone. True when it did, and
    /// the structure on screen, if any, has to be fetched again now.
    @discardableResult
    internal func settleOwedRefetch() -> Bool {
        guard owesRefetch, !changeManager.hasChanges else { return false }
        markStructureStale()
        return true
    }

    /// Every sub-tab is fetched again from here, which answers an owed change too.
    internal func markEveryTabStale() {
        tabData.markAllStale()
        owesRefetch = false
    }

    internal func reloadConcurrentRefreshAvailability(
        provider: any ScopedMetadataProviding = DatabaseManager.shared
    ) async {
        guard objectKind == .materializedView else { return }
        concurrentRefreshRequest += 1
        let request = concurrentRefreshRequest
        concurrentRefresh = concurrentRefresh.enteringLoad
        let loader = TableStructureLoader(scope: scope, tableName: tableName, provider: provider)
        let outcome: MetadataFetchOutcome<PluginConcurrentRefreshAvailability?>
        do {
            outcome = .fetched(try await loader.concurrentRefreshAvailability())
        } catch is CancellationError {
            outcome = .cancelled
        } catch {
            Self.logger.error(
                "Concurrent refresh check failed: \(error.publicLogShape, privacy: .public)"
            )
            outcome = .failed(error.localizedDescription)
        }
        guard request == concurrentRefreshRequest else { return }
        concurrentRefresh = concurrentRefresh.settled(by: outcome, discardingValue: true)
    }

    /// Breaks the cycle the mounted view's wiring creates.
    ///
    /// `TableStructureView.onAppear` installs closures on `gridDelegate`, and each captures the view
    /// struct, which holds this session and the coordinator. So session owns delegate owns closure
    /// owns session: dropping the session from `structureSessions` would not release it, its change
    /// manager, or the connection it names. Called wherever a session is dropped, never from
    /// `onDisappear`, because appearance is not lifetime.
    internal func releaseViewWiring() {
        gridDelegate.onSelectedRowsChanged = nil
        gridDelegate.sortHandler = nil
        gridDelegate.moveRowHandler = nil
        gridDelegate.currentProvider = nil
        gridDelegate.coordinator = nil
    }
}

internal struct StructureFooterCapability: Equatable {
    internal var canAdd = false
    internal var canRemove = false
    internal var addLabel = ""
    internal var removeLabel = ""

    /// Why the pair is dimmed, for the tooltip. Empty when it is not.
    internal var unavailableReason: String?

    internal var isActive: Bool {
        !addLabel.isEmpty
    }
}
