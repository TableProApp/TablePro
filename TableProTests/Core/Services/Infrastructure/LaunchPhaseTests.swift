//
//  LaunchPhaseTests.swift
//  TableProTests
//

@testable import TablePro
import XCTest

final class LaunchPhaseTests: XCTestCase {
    func testLaunchingAndCollectingAcceptIntents() {
        XCTAssertTrue(LaunchPhase.launching.isAcceptingIntents)
        XCTAssertTrue(LaunchPhase.collectingIntents.isAcceptingIntents)
    }

    func testRoutingAndReadyRefuseIntents() {
        XCTAssertFalse(LaunchPhase.routing.isAcceptingIntents)
        XCTAssertFalse(LaunchPhase.ready.isAcceptingIntents)
    }

    func testOnlyReadyReportsReady() {
        XCTAssertFalse(LaunchPhase.launching.isReady)
        XCTAssertFalse(LaunchPhase.collectingIntents.isReady)
        XCTAssertFalse(LaunchPhase.routing.isReady)
        XCTAssertTrue(LaunchPhase.ready.isReady)
    }
}
