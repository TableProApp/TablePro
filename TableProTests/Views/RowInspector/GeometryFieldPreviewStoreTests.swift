//
//  GeometryFieldPreviewStoreTests.swift
//  TableProTests
//
//  The inspector redraws every field on each keystroke in any of them, so a geometry field must
//  not read its value once per pass, and a value large enough to cost milliseconds must not be
//  read during a pass at all.
//

import Foundation
@testable import TablePro
import Testing

@MainActor
struct GeometryFieldPreviewStoreTests {
    private typealias Request = GeometryFieldPreviewStore.Request

    private func request(_ text: String) -> Request {
        Request(text: text, state: .value(text))
    }

    /// 6,000 vertices, about 66,000 characters: past the limit and still well inside the budget.
    private var largeLine: String {
        let vertices = (0 ..< 6_000).map { "\($0 % 170).5 \($0 % 80).5" }
        return "LINESTRING(" + vertices.joined(separator: ",") + ")"
    }

    private func isDrawable(_ preview: GeometryFieldPreview?) -> Bool {
        if case .drawable = preview { return true }
        return false
    }

    @Test("A value is read once, however often it is asked for")
    func sameValueIsReadOnce() {
        let store = GeometryFieldPreviewStore()
        let first = store.resolve(request("POINT(1 2)"), source: .spatialColumn)
        let token = store.token
        let second = store.resolve(request("POINT(1 2)"), source: .spatialColumn)

        #expect(isDrawable(first.preview))
        #expect(first.pending == nil)
        #expect(second.preview == first.preview)
        #expect(store.token == token)
    }

    @Test("A new value is read and moves the token")
    func newValueMovesTheToken() {
        let store = GeometryFieldPreviewStore()
        let first = store.resolve(request("POINT(1 2)"), source: .spatialColumn)
        let token = store.token
        let second = store.resolve(request("POINT(3 4)"), source: .spatialColumn)

        #expect(second.preview != first.preview)
        #expect(store.token != token)
    }

    @Test("A stored NULL and an empty value are told apart")
    func nullIsNotAnEmptyValue() {
        let store = GeometryFieldPreviewStore()
        let null = store.resolve(Request(text: "", state: .null), source: .spatialColumn)
        let empty = store.resolve(Request(text: "", state: .value("")), source: .spatialColumn)

        #expect(null.preview == .unavailable(.null))
        #expect(empty.preview == .unavailable(.unreadable))
    }

    @Test("The limit is the last length read during a pass")
    func theLimitIsInclusive() {
        let limit = GeometryFieldPreview.synchronousLimit
        let store = GeometryFieldPreviewStore()

        let atLimit = store.resolve(request(String(repeating: "x", count: limit)), source: .spatialColumn)
        #expect(atLimit.pending == nil)
        #expect(atLimit.preview != nil)

        let past = request(String(repeating: "x", count: limit + 1))
        #expect(store.resolve(past, source: .spatialColumn).pending == past)
    }

    @Test("A large value is left for the task and the previous map stays up")
    func largeValueKeepsThePreviousMap() {
        let store = GeometryFieldPreviewStore()
        let previous = store.resolve(request("POINT(1 2)"), source: .spatialColumn)
        let token = store.token

        let large = request(largeLine)
        let resolution = store.resolve(large, source: .spatialColumn)

        #expect(resolution.pending == large)
        #expect(resolution.preview == previous.preview)
        #expect(store.token == token)
    }

    @Test("A large value with nothing before it has no preview yet")
    func firstLargeValueHasNoPreview() {
        let store = GeometryFieldPreviewStore()
        let resolution = store.resolve(request(largeLine), source: .spatialColumn)

        #expect(resolution.preview == nil)
        #expect(resolution.pending != nil)
    }

    @Test("Loading a large value commits it")
    func loadCommits() async {
        let store = GeometryFieldPreviewStore()
        let large = request(largeLine)
        _ = store.resolve(large, source: .spatialColumn)
        let token = store.token

        let loaded = await store.load(large, source: .spatialColumn)
        #expect(isDrawable(loaded))
        #expect(store.token != token)

        let after = store.resolve(large, source: .spatialColumn)
        #expect(after.pending == nil)
        #expect(after.preview == loaded)
    }

    /// A pane that is re-added restarts its tasks with the id they already ran for.
    @Test("Loading the same value again reads nothing")
    func reloadIsIdempotent() async {
        let store = GeometryFieldPreviewStore()
        let large = request(largeLine)
        _ = store.resolve(large, source: .spatialColumn)
        let first = await store.load(large, source: .spatialColumn)
        let token = store.token

        let second = await store.load(large, source: .spatialColumn)
        #expect(second == first)
        #expect(store.token == token)
    }

    @Test("A read the value has moved on from commits nothing")
    func overtakenReadIsDropped() async {
        let store = GeometryFieldPreviewStore()
        let large = request(largeLine)
        _ = store.resolve(large, source: .spatialColumn)
        let current = store.resolve(request("POINT(1 2)"), source: .spatialColumn)
        let token = store.token

        let loaded = await store.load(large, source: .spatialColumn)
        #expect(loaded == nil)
        #expect(store.token == token)
        #expect(store.preview == current.preview)
    }
}
