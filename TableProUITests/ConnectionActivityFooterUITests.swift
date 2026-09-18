import XCTest

/// The connection switcher's footer names the transport the window is on. The sample database is a
/// local file with no transport in front of it, so the deterministic assertion is the one this test
/// makes: the footer is there, and it reads Direct.
///
/// A tunnelled connection is not covered here, because a byte count needs a live SSH server and a
/// query moving data through it. `SSHChannelRelayTests`, `TransportRateSamplerTests` and
/// `ConnectionTransportActivityTests` cover the counting, the rate and the per-transport choice.
final class ConnectionActivityFooterUITests: UITestCase {
    func testTheSwitcherNamesTheTransportTheWindowIsOn() throws {
        let app = try launchWithSampleDatabase()

        app.typeKey("c", modifierFlags: [.command, .control])

        let field = app.searchFields.matching(
            NSPredicate(format: "placeholderValue BEGINSWITH[c] %@", "Search connections")
        ).firstMatch
        XCTAssertTrue(field.waitToExist(timeout: 15), "The connection switcher never opened")

        let transport = app.staticTexts["connection-activity-transport"]
        XCTAssertTrue(transport.waitToExist(timeout: 10), "The switcher must carry a transport footer")
        XCTAssertEqual(
            transport.value as? String,
            "Direct",
            "A connection with no tunnel must read as Direct"
        )

        app.typeKey(.escape, modifierFlags: [])
        XCTAssertTrue(field.waitForNonExistence(timeout: 10), "Escape must dismiss the switcher")
    }
}
