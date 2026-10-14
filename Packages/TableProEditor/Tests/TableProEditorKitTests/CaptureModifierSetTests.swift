import Foundation
@testable import TableProEditorKit
import Testing

@MainActor
struct CaptureModifierSetTests {
    @Test func test_init() {
        // Init empty
        let set1 = CaptureModifierSet(rawValue: 0)
        #expect(set1.isEmpty)
        #expect(set1.values.isEmpty)

        // Init with multiple values
        let set2 = CaptureModifierSet(rawValue: 0b1101)
        #expect(set2 == [.declaration, .readonly, .static])
        #expect(set2.values == [.declaration, .readonly, .static])
    }

    @Test func test_insert() {
        var set = CaptureModifierSet(rawValue: 0)
        #expect(set.isEmpty)

        // Insert one item
        set.insert(.declaration)
        #expect(set == [.declaration])

        // Inserting again does nothing
        set.insert(.declaration)
        #expect(set == [.declaration])

        // Insert more items
        set.insert(.declaration)
        set.insert(.async)
        set.insert(.documentation)
        #expect(set == [.declaration, .async, .documentation])

        // Order doesn't matter
        #expect(set == [.async, .declaration, .documentation])
    }

    @Test func test_values() {
        // Invalid rawValue returns non-garbage results
        var set = CaptureModifierSet([.declaration, .readonly, .static])
        set.rawValue |= 1 << 48 // No real modifier with raw value 48, but we still have all the other values

        #expect(set.values == [.declaration, .readonly, .static])

        set = CaptureModifierSet()
        set.insert(.declaration)
        set.insert(.async)
        set.insert(.documentation)
        #expect(set.values == [.declaration, .async, .documentation])
        #expect(set.values != [.declaration, .documentation, .async]) // Order matters
    }
}
