import TableProPluginKit
import Testing
@testable import TablePro

@Suite("DatabaseType Redis Properties")
struct DatabaseTypeRedisTests {
    @Test("Default port is 6379")
    func defaultPort() {
        #expect(DatabaseType.redis.defaultPort == 6_379)
    }

    @Test("Icon name is redis-icon")
    func iconName() {
        #expect(DatabaseType.redis.iconName == "redis-icon")
    }

    @Test("Does not require authentication")
    func requiresAuthentication() {
        #expect(DatabaseType.redis.requiresAuthentication == false)
    }

    @Test("Does not support foreign keys")
    func supportsForeignKeys() {
        #expect(DatabaseType.redis.supportsForeignKeys == false)
    }

    @Test("Does not support schema editing")
    func supportsSchemaEditing() {
        #expect(DatabaseType.redis.supportsSchemaEditing == false)
    }

    @Test("Raw value is Redis")
    func rawValue() {
        #expect(DatabaseType.redis.rawValue == "Redis")
    }

    @Test("Theme color is derived from plugin brand color")
    @MainActor func themeColor() {
        #expect(DatabaseType.redis.themeColor == PluginManager.shared.brandColor(for: .redis))
    }

    @Test("Included in allKnownTypes")
    func includedInAllKnownTypes() {
        #expect(DatabaseType.allKnownTypes.contains(.redis))
    }

    @Test("Included in allCases shim")
    func includedInAllCases() {
        #expect(DatabaseType.allCases.contains(.redis))
    }
}
