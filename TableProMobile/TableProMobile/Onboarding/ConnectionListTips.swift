import Foundation
import os
import SwiftUI
import TipKit

nonisolated struct FavoriteSwipeTip: Tip {
    static let tipId = "favorite-swipe"

    @Parameter static var isListReady: Bool = false
    @Parameter static var connectionCount: Int = 0
    @Parameter static var hasFavorites: Bool = false

    var id: String { Self.tipId }

    var title: Text {
        Text("Keep Connections at the Top")
    }

    var message: Text? {
        Text("Swipe right on a connection to add it to Favorites.")
    }

    var image: Image? {
        Image(systemName: "star")
    }

    var rules: [Rule] {
        #Rule(Self.$isListReady) { $0 == true }
        #Rule(Self.$connectionCount) { $0 >= 3 }
        #Rule(Self.$hasFavorites) { $0 == false }
    }

    var options: [any TipOption] {
        Tips.MaxDisplayCount(2)
    }
}

nonisolated struct ConnectionActionsTip: Tip {
    static let tipId = "connection-actions"
    static let connectionOpened = Tips.Event(id: "connection-opened")

    var id: String { Self.tipId }

    var title: Text {
        Text("More Actions")
    }

    var message: Text? {
        Text("Touch and hold a connection to rename, duplicate, or move it to a group.")
    }

    var image: Image? {
        Image(systemName: "hand.tap")
    }

    var rules: [Rule] {
        #Rule(FavoriteSwipeTip.$isListReady) { $0 == true }
        #Rule(Self.connectionOpened) { $0.donations.count >= 3 }
    }

    var options: [any TipOption] {
        Tips.MaxDisplayCount(2)
    }
}

nonisolated struct TagSearchTip: Tip {
    static let tipId = "tag-search"

    @Parameter static var hasTaggedConnections: Bool = false

    var id: String { Self.tipId }

    var title: Text {
        Text("Filter by Tag")
    }

    var message: Text? {
        Text("Type a tag's name in the search field to show only the connections that carry it.")
    }

    var image: Image? {
        Image(systemName: "tag")
    }

    var rules: [Rule] {
        #Rule(FavoriteSwipeTip.$isListReady) { $0 == true }
        #Rule(Self.$hasTaggedConnections) { $0 == true }
        #Rule(ConnectionActionsTip.connectionOpened) { $0.donations.count >= 1 }
    }

    var options: [any TipOption] {
        Tips.MaxDisplayCount(2)
    }
}

enum ConnectionListTips {
    private static let logger = Logger(subsystem: "com.TablePro", category: "ConnectionListTips")

    private(set) static var isConfigured = false

    static func configure(isTestRuntime: Bool = TestRuntime.isActive) {
        guard !isTestRuntime, !isConfigured else { return }
        do {
            try Tips.configure([.displayFrequency(.daily)])
            isConfigured = true
        } catch {
            logger.error("Could not configure tips: \(error.localizedDescription, privacy: .public)")
        }
    }

    static func makeGroup() -> TipGroup {
        TipGroup(.firstAvailable) {
            FavoriteSwipeTip()
            ConnectionActionsTip()
            TagSearchTip()
        }
    }

    static func libraryChanged(
        isListReady: Bool,
        connectionCount: Int,
        hasFavorites: Bool,
        hasTaggedConnections: Bool
    ) {
        guard isConfigured else { return }
        FavoriteSwipeTip.isListReady = isListReady
        FavoriteSwipeTip.connectionCount = connectionCount
        FavoriteSwipeTip.hasFavorites = hasFavorites
        TagSearchTip.hasTaggedConnections = hasTaggedConnections
    }

    static func connectionOpened() {
        guard isConfigured else { return }
        ConnectionActionsTip.connectionOpened.sendDonation()
    }

    static func favoriteSet() {
        invalidate(FavoriteSwipeTip())
    }

    static func connectionMenuUsed() {
        invalidate(ConnectionActionsTip())
    }

    static func tagFilterUsed() {
        invalidate(TagSearchTip())
    }

    private static func invalidate(_ tip: some Tip) {
        guard isConfigured else { return }
        tip.invalidate(reason: .actionPerformed)
    }
}
