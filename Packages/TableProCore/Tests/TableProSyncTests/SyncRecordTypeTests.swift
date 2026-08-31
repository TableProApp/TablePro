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

    @Test("A name that already fits is returned unchanged", arguments: SyncRecordType.allCases)
    func namesThatFitAreUnchanged(_ type: SyncRecordType) {
        let id = String(repeating: "a", count: SyncRecordName.maximumLength - type.recordNamePrefix.count)
        let name = type.recordName(for: id)
        #expect(name == type.recordNamePrefix + id)
        #expect((name as NSString).length == SyncRecordName.maximumLength)
    }

    @Test("A name one unit too long is shortened", arguments: SyncRecordType.allCases)
    func namesPastTheLimitAreShortened(_ type: SyncRecordType) {
        let id = String(repeating: "a", count: SyncRecordName.maximumLength - type.recordNamePrefix.count + 1)
        let name = type.recordName(for: id)
        #expect((name as NSString).length <= SyncRecordName.maximumLength)
        #expect(name.hasPrefix(type.recordNamePrefix + SyncRecordName.digestPrefix))
    }

    /// The limit CloudKit enforces counts UTF-16 code units, so a name of 128 emoji is over it at
    /// 128 characters. `scripts/check-cloudkit-record-name-limit.sh` measures that.
    @Test("The limit counts UTF-16 code units, not characters")
    func theLimitCountsUTF16CodeUnits() {
        let id = String(repeating: "😀", count: 200)
        #expect(id.count < SyncRecordName.maximumLength)
        let name = SyncRecordType.settings.recordName(for: id)
        #expect((name as NSString).length <= SyncRecordName.maximumLength)
        #expect(name.hasPrefix("Settings_" + SyncRecordName.digestPrefix))
    }

    @Test("Shortening is stable, so two devices agree on the record")
    func shorteningIsDeterministic() {
        let id = String(repeating: "path/to/database.sqlite", count: 40)
        #expect(SyncRecordType.settings.recordName(for: id) == SyncRecordType.settings.recordName(for: id))
        #expect(
            SyncRecordType.settings.recordName(for: id) == "Settings_sha256-"
                + SyncRecordName.digest(of: id)
        )
    }

    @Test("Two long identifiers do not collapse onto one record")
    func distinctLongIdentifiersStayDistinct() {
        let base = String(repeating: "a", count: 300)
        #expect(SyncRecordType.settings.recordName(for: base) != SyncRecordType.settings.recordName(for: base + "b"))
    }

    /// The column layout category that produced #2575: a connection UUID, a percent-encoded
    /// SQLite file path, an empty schema and a table name.
    @Test("A long SQLite path produces a name CloudKit accepts")
    func aLongSQLitePathFits() {
        let path = "/Users/example/projects/acme/api/.wrangler/state/v3/d1"
            + "/miniflare-D1DatabaseObject/"
            + String(repeating: "f", count: 64) + ".sqlite"
        let parts = [UUID().uuidString, path, "", "d1_migrations"]
            .map { $0.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? $0 }
        let category = "columnLayout." + parts.joined(separator: ".")

        #expect((("Settings_" + category) as NSString).length > SyncRecordName.maximumLength)
        #expect((SyncRecordType.settings.recordName(for: category) as NSString).length
            <= SyncRecordName.maximumLength)
    }
}
