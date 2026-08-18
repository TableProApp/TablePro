//
//  SmokeCaptureTests.swift
//  TableProScreenshots
//

import XCTest

/// The one test that proves the capture path works at all: the seeded connection opens, the window
/// is pinned to the size the site expects, `screencapture` is allowed to run, and the file it wrote
/// carries the transparency the page needs. Every shot below assumes all four.
final class SmokeCaptureTests: ScreenshotCase {
    func testCapturesTheWindowAtTheSizeTheSiteExpects() throws {
        let app = try launchForScreenshot(appearance: .light, connections: [.mariadb])
        let window = openFirstConnection(in: app)
        try capture(window, named: "smoke")
    }
}
