import AppKit
@testable import TableProEditorKit
import Testing

// swiftlint:disable all
@MainActor
struct TableProEditorKitTests {

    // MARK: NSFont Line Height

    @Test func test_LineHeight() throws {
        let font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
        let result = font.lineHeight
        let expected = 15.0
        #expect(result == expected)
    }

    @Test func test_LineHeight2() throws {
        let font = NSFont.monospacedSystemFont(ofSize: 0, weight: .regular)
        let result = font.lineHeight
        let expected = 16.0
        #expect(result == expected)
    }

    // MARK: String NSRange

    @Test("An NSRange subscript reads the same text across a newline", arguments: [
        "Hello, World",
        "Hello,\nWorld",
    ])
    func test_StringSubscriptNSRange(_ testString: String) throws {
        let testRange = NSRange(location: 7, length: 5)

        let result = String(testString[testRange]!)
        let expected = "World"
        #expect(result == expected)
    }
}
// swiftlint:enable all
