import Foundation
@testable import TableProTextEngine
import Testing

@MainActor
final class KillRingTests {
    @Test func test_killRingYank() {
        var ring = KillRing.shared
        ring.kill(strings: ["hello"])
        for _ in 0..<100 {
            #expect(ring.yank() == ["hello"])
        }

        ring.kill(strings: ["hello", "multiple", "strings"])
        // should never change on yank
        for _ in 0..<100 {
            #expect(ring.yank() == ["hello", "multiple", "strings"])
        }

        ring = KillRing(2)
        ring.kill(strings: ["hello"])
        for _ in 0..<100 {
            #expect(ring.yank() == ["hello"])
        }

        ring.kill(strings: ["hello", "multiple", "strings"])
        // should never change on yank
        for _ in 0..<100 {
            #expect(ring.yank() == ["hello", "multiple", "strings"])
        }
    }

    @Test func test_killRingYankAndSelect() {
        let ring = KillRing(5)
        ring.kill(strings: ["1"])
        ring.kill(strings: ["2"])
        ring.kill(strings: ["3", "3", "3"])
        ring.kill(strings: ["4", "4"])
        ring.kill(strings: ["5"])
        // should loop
        for _ in 0..<5 {
            #expect(ring.yankAndSelect() == ["5"])
            #expect(ring.yankAndSelect() == ["1"])
            #expect(ring.yankAndSelect() == ["2"])
            #expect(ring.yankAndSelect() == ["3", "3", "3"])
            #expect(ring.yankAndSelect() == ["4", "4"])
        }
    }

    @Test func test_textViewYank() {
        let view = TextView(string: "Hello World")
        view.selectionManager.setSelectedRange(NSRange(location: 0, length: 1))
        view.delete(self)
        #expect(view.string == "ello World")

        view.yank(self)
        #expect(view.string == "Hello World")
        view.selectionManager.setSelectedRange(NSRange(location: 0, length: 0))
        view.yank(self)
        #expect(view.string == "HHello World")
    }

    @Test func test_textViewYankMultipleCursors() {
        let view = TextView(string: "Hello World")
        view.selectionManager.setSelectedRanges([NSRange(location: 1, length: 0), NSRange(location: 4, length: 0)])
        view.delete(self)
        #expect(view.string == "elo World")

        view.yank(self)
        #expect(view.string == "Hello World")
        view.selectionManager.setSelectedRanges([NSRange(location: 0, length: 0)])
        view.yank(self)
        #expect(view.string == "H\nlHello World")
    }
}
