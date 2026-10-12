//
//  CommitFenceTests.swift
//  TableProTests
//

import Foundation
@testable import TablePro
import Testing

struct CommitFenceTests {
    @Test("a load that started before its key was superseded may not commit")
    func supersededTokenIsRefused() {
        var fence = CommitFence<String>()
        let stale = fence.token(for: "shop.public")

        fence.supersede("shop.public")
        let fresh = fence.token(for: "shop.public")

        #expect(!fence.isCurrent(stale, for: "shop.public"))
        #expect(fence.isCurrent(fresh, for: "shop.public"))
    }

    @Test("superseding one key leaves loads on other keys free to commit")
    func otherKeysAreUnaffected() {
        var fence = CommitFence<String>()
        let other = fence.token(for: "warehouse.public")

        fence.supersede("shop.public")

        #expect(fence.isCurrent(other, for: "warehouse.public"))
    }

    @Test("loads that started together share a token and both stay current")
    func concurrentLoadsShareAToken() {
        let fence = CommitFence<Int>()
        let first = fence.token(for: 1)
        let second = fence.token(for: 1)

        #expect(first == second)
        #expect(fence.isCurrent(first, for: 1) && fence.isCurrent(second, for: 1))
    }
}
