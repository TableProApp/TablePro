import XCTest
@testable import CodeEditSourceEditor

// swiftlint:disable all
final class CodeEditSourceEditorTests: XCTestCase {

    // MARK: NSFont Line Height

    func test_LineHeight() throws {
        let font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
        let result = font.lineHeight
        let expected = 15.0
        XCTAssertEqual(result, expected)
    }

    func test_LineHeight2() throws {
        let font = NSFont.monospacedSystemFont(ofSize: 0, weight: .regular)
        let result = font.lineHeight
        let expected = 16.0
        XCTAssertEqual(result, expected)
    }

    // MARK: String NSRange

    func test_StringSubscriptNSRange() throws {
        let testString = "Hello, World"
        let testRange = NSRange(location: 7, length: 5)

        let result = String(testString[testRange]!)
        let expected = "World"
        XCTAssertEqual(result, expected)
    }

    func test_StringSubscriptNSRange2() throws {
        let testString = "Hello,\nWorld"
        let testRange = NSRange(location: 7, length: 5)

        let result = String(testString[testRange]!)
        let expected = "World"
        XCTAssertEqual(result, expected)
    }
}
// swiftlint:enable all
