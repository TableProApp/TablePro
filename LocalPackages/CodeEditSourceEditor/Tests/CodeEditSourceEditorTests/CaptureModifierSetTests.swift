import XCTest
@testable import CodeEditSourceEditor

final class CaptureModifierSetTests: XCTestCase {
    func test_init() {
        // Init empty
        let set1 = CaptureModifierSet(rawValue: 0)
        XCTAssertEqual(set1, [])
        XCTAssertEqual(set1.values, [])

        // Init with multiple values
        let set2 = CaptureModifierSet(rawValue: 0b1101)
        XCTAssertEqual(set2, [.declaration, .readonly, .static])
        XCTAssertEqual(set2.values, [.declaration, .readonly, .static])
    }

    func test_insert() {
        var set = CaptureModifierSet(rawValue: 0)
        XCTAssertEqual(set, [])

        // Insert one item
        set.insert(.declaration)
        XCTAssertEqual(set, [.declaration])

        // Inserting again does nothing
        set.insert(.declaration)
        XCTAssertEqual(set, [.declaration])

        // Insert more items
        set.insert(.declaration)
        set.insert(.async)
        set.insert(.documentation)
        XCTAssertEqual(set, [.declaration, .async, .documentation])

        // Order doesn't matter
        XCTAssertEqual(set, [.async, .declaration, .documentation])
    }

    func test_values() {
        // Invalid rawValue returns non-garbage results
        var set = CaptureModifierSet([.declaration, .readonly, .static])
        set.rawValue |= 1 << 48 // No real modifier with raw value 48, but we still have all the other values

        XCTAssertEqual(set.values, [.declaration, .readonly, .static])

        set = CaptureModifierSet()
        set.insert(.declaration)
        set.insert(.async)
        set.insert(.documentation)
        XCTAssertEqual(set.values, [.declaration, .async, .documentation])
        XCTAssertNotEqual(set.values, [.declaration, .documentation, .async]) // Order matters
    }
}
