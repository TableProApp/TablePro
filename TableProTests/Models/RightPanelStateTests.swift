//
//  RightPanelStateTests.swift
//  TableProTests
//
//  Tests for RightPanelState persistence of isPresented via UserDefaults.
//

import Foundation
@testable import TablePro
import Testing

@Suite("RightPanelState", .serialized)
struct RightPanelStateTests {
    private static let key = "com.TablePro.rightPanel.isPresented"

    /// Yields to the main dispatch queue so deferred DispatchQueue.main.async blocks execute.
    private func yieldToMainQueue() async {
        await withCheckedContinuation { continuation in
            DispatchQueue.main.async {
                continuation.resume()
            }
        }
    }

    @Test("isPresented defaults to false when no UserDefaults value")
    @MainActor
    func defaultsToFalse() {
        UserDefaults.standard.removeObject(forKey: Self.key)
        let state = RightPanelState()
        #expect(state.isPresented == false)
    }

    @Test("isPresented initializes from UserDefaults when true")
    @MainActor
    func initializesFromUserDefaults() {
        UserDefaults.standard.set(true, forKey: Self.key)
        let state = RightPanelState()
        #expect(state.isPresented == true)
        UserDefaults.standard.removeObject(forKey: Self.key)
    }

    @Test("isPresented persists to UserDefaults on change (deferred)")
    @MainActor
    func persistsOnChange() async {
        UserDefaults.standard.removeObject(forKey: Self.key)
        let state = RightPanelState()
        state.isPresented = true
        // UserDefaults write is deferred via DispatchQueue.main.async
        await yieldToMainQueue()
        #expect(UserDefaults.standard.bool(forKey: Self.key) == true)
        state.isPresented = false
        await yieldToMainQueue()
        #expect(UserDefaults.standard.bool(forKey: Self.key) == false)
        UserDefaults.standard.removeObject(forKey: Self.key)
    }

    @Test("isPresented does not persist synchronously (deferred write)")
    @MainActor
    func doesNotPersistSynchronously() async {
        UserDefaults.standard.removeObject(forKey: Self.key)
        let state = RightPanelState()
        state.isPresented = true
        // Write is deferred — UserDefaults should still be false immediately
        #expect(UserDefaults.standard.bool(forKey: Self.key) == false)
        // Drain so the deferred write completes before next test
        await yieldToMainQueue()
        UserDefaults.standard.removeObject(forKey: Self.key)
    }

    @Test("new instance reads persisted state from previous instance")
    @MainActor
    func newInstanceReadsPersisted() async {
        UserDefaults.standard.removeObject(forKey: Self.key)
        let state1 = RightPanelState()
        state1.isPresented = true
        // Wait for deferred UserDefaults write
        await yieldToMainQueue()

        let state2 = RightPanelState()
        #expect(state2.isPresented == true)
        UserDefaults.standard.removeObject(forKey: Self.key)
    }

    @Test("teardown is idempotent - calling twice does not crash")
    @MainActor
    func teardownIdempotent() {
        let state = RightPanelState()
        state.teardown()
        state.teardown()
    }

    @Test("teardown nils schemaProvider on aiViewModel")
    @MainActor
    func teardown_nilsSchemaProvider() {
        let state = RightPanelState()
        state.aiViewModel.schemaProvider = SQLSchemaProvider()
        #expect(state.aiViewModel.schemaProvider != nil)

        state.teardown()

        #expect(state.aiViewModel.schemaProvider == nil)
    }

    @Test("teardown nils onSave closure")
    @MainActor
    func teardown_nilsOnSave() {
        let state = RightPanelState()
        state.onSave = { }
        #expect(state.onSave != nil)

        state.teardown()

        #expect(state.onSave == nil)
    }
}
