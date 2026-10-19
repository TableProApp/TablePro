//
//  ResultPaneProjectionState.swift
//  TablePro
//

import Foundation

/// What a result pane's projection was built from. The subject is the part that decides whether an
/// older projection may stand in while a new one builds: the tab and the columns drawn. The result
/// set is not part of it, because every refresh, page turn and sort installs a new result set.
protocol ResultPaneProjectionKey: Hashable {
    associatedtype Subject: Hashable
    var subject: Subject { get }
}

/// The projection a chart or map pane draws, and the key it was built for.
///
/// The pane's view survives a tab switch and a result-set switch (its hosting split view reassigns
/// `rootView`), so a projection is shown only for its own subject. Within it, the old drawing stays
/// up while its replacement builds: a refresh, a re-sort or a page turn never blanks the pane to a
/// spinner.
struct ResultPaneProjectionState<Projection, Key: ResultPaneProjectionKey> {
    private(set) var projection: Projection?
    private(set) var key: Key?

    func isCurrent(for key: Key) -> Bool {
        self.key == key
    }

    func projection(for key: Key) -> Projection? {
        guard let loaded = self.key, loaded.subject == key.subject else { return nil }
        return projection
    }

    mutating func commit(_ projection: Projection, for key: Key) {
        self.projection = projection
        self.key = key
    }
}
