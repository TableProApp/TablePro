import Foundation
@testable import TablePro
import Testing

struct PluginWinnerSelectionTests {
    private let bundleId = "com.TablePro.ExampleDriver"

    private func candidate(_ source: PluginSource, build: Int) -> PluginManager.PluginCandidate {
        let folder = source == .builtIn ? "/Applications/TablePro.app/Contents/PlugIns" : "/tmp/Plugins"
        return PluginManager.PluginCandidate(
            url: URL(fileURLWithPath: "\(folder)/ExampleDriver.tableplugin"),
            source: source,
            bundleId: bundleId,
            build: build
        )
    }

    private func winner(
        builtIn: PluginManager.PluginCandidate,
        user: PluginManager.PluginCandidate,
        userFirst: Bool
    ) throws -> PluginManager.PluginCandidate {
        let candidates = userFirst ? [user, builtIn] : [builtIn, user]
        let winners = PluginManager.selectWinners(candidates: candidates)
        #expect(winners.count == 1)
        return try #require(winners[bundleId])
    }

    @Test("A user copy with a lower build loses to the built-in copy", arguments: [false, true])
    func lowerBuildUserCopyLoses(userFirst: Bool) throws {
        let builtIn = candidate(.builtIn, build: 820_099)
        let user = candidate(.userInstalled, build: 820_001)

        let picked = try winner(builtIn: builtIn, user: user, userFirst: userFirst)

        #expect(picked.source == .builtIn)
        #expect(picked.url == builtIn.url)
    }

    @Test("A user copy with a higher build wins over the built-in copy", arguments: [false, true])
    func higherBuildUserCopyWins(userFirst: Bool) throws {
        let builtIn = candidate(.builtIn, build: 820_099)
        let user = candidate(.userInstalled, build: 820_199)

        let picked = try winner(builtIn: builtIn, user: user, userFirst: userFirst)

        #expect(picked.source == .userInstalled)
        #expect(picked.url == user.url)
    }

    @Test("An equal build goes to the built-in copy", arguments: [false, true])
    func tieGoesToBuiltIn(userFirst: Bool) throws {
        let builtIn = candidate(.builtIn, build: 1)
        let user = candidate(.userInstalled, build: 1)

        let picked = try winner(builtIn: builtIn, user: user, userFirst: userFirst)

        #expect(picked.source == .builtIn)
        #expect(picked.url == builtIn.url)
    }
}
