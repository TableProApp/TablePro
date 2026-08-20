//
//  SessionTabStatePersisting.swift
//  TablePro
//

import Foundation

/// Disconnecting leaves the window open, so a connection's tabs have to reach disk before the
/// session goes away and the coordinator holding them is torn down. `DatabaseManager` cannot reach
/// the view layer, so the app installs the persister at launch and every disconnect runs through it.
@MainActor
internal protocol SessionTabStatePersisting: AnyObject {
    func persistTabState(for connectionId: UUID)
}
