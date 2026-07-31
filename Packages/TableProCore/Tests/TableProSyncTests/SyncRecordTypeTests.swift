import Foundation
import Testing

import TableProSyncTransport

@Suite("Sync record type naming")
struct SyncRecordTypeTests {
    @Test("Every type round-trips its record name", arguments: SyncRecordType.allCases)
    func roundTripsEveryCase(_ type: SyncRecordType) {
        let id = UUID().uuidString
        let parsed = SyncRecordType.parse(recordName: type.recordName(for: id))
        #expect(parsed?.type == type)
        #expect(parsed?.id == id)
    }

    @Test("An ambiguous prefix resolves to the longest match")
    func ambiguousPrefixesResolveToLongestMatch() {
        #expect(SyncRecordType.parse(recordName: "Favorite_abc")?.type == .favorite)
        #expect(SyncRecordType.parse(recordName: "FavoriteFolder_abc")?.type == .favoriteFolder)
        #expect(SyncRecordType.parse(recordName: "FavoriteTable_abc")?.type == .tableFavorite)
    }

    @Test("An ambiguous prefix keeps the whole identifier")
    func ambiguousPrefixesKeepTheIdentifier() {
        #expect(SyncRecordType.parse(recordName: "FavoriteFolder_abc")?.id == "abc")
        #expect(SyncRecordType.parse(recordName: "FavoriteTable_abc")?.id == "abc")
    }

    @Test("An unknown prefix does not parse")
    func unknownPrefixDoesNotParse() {
        #expect(SyncRecordType.parse(recordName: "Unknown_abc") == nil)
        #expect(SyncRecordType.parse(recordName: "abc") == nil)
        #expect(SyncRecordType.parse(recordName: "") == nil)
    }

    @Test("Record name prefixes are the ones already on the wire")
    func prefixesMatchTheShippedWireFormat() {
        #expect(SyncRecordType.connection.recordNamePrefix == "Connection_")
        #expect(SyncRecordType.group.recordNamePrefix == "Group_")
        #expect(SyncRecordType.tag.recordNamePrefix == "Tag_")
        #expect(SyncRecordType.settings.recordNamePrefix == "Settings_")
        #expect(SyncRecordType.favorite.recordNamePrefix == "Favorite_")
        #expect(SyncRecordType.favoriteFolder.recordNamePrefix == "FavoriteFolder_")
        #expect(SyncRecordType.tableFavorite.recordNamePrefix == "FavoriteTable_")
        #expect(SyncRecordType.sshProfile.recordNamePrefix == "SSHProfile_")
    }

    @Test("Record types are the ones already on the wire")
    func rawValuesMatchTheShippedWireFormat() {
        #expect(SyncRecordType.connection.rawValue == "Connection")
        #expect(SyncRecordType.group.rawValue == "ConnectionGroup")
        #expect(SyncRecordType.tag.rawValue == "ConnectionTag")
        #expect(SyncRecordType.settings.rawValue == "AppSettings")
        #expect(SyncRecordType.favorite.rawValue == "SQLFavorite")
        #expect(SyncRecordType.favoriteFolder.rawValue == "SQLFavoriteFolder")
        #expect(SyncRecordType.tableFavorite.rawValue == "FavoriteTable")
        #expect(SyncRecordType.sshProfile.rawValue == "SSHProfile")
    }

    @Test("No two types share a record name prefix")
    func prefixesAreDistinct() {
        let prefixes = SyncRecordType.allCases.map(\.recordNamePrefix)
        #expect(Set(prefixes).count == prefixes.count)
    }
}
