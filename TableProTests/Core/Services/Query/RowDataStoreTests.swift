//
//  RowDataStoreTests.swift
//  TableProTests
//

import Foundation
import Testing
@testable import TablePro

@Suite("RowDataStore")
@MainActor
struct RowDataStoreTests {

    @Test("buffer(for:) creates an empty RowBuffer on first access and returns the same instance after")
    func bufferCreatesAndReturnsSameInstance() {
        let store = RowDataStore()
        let tabId = UUID()

        let first = store.buffer(for: tabId)
        #expect(first.rows.isEmpty)
        #expect(first.columns.isEmpty)
        #expect(first.isEvicted == false)

        let second = store.buffer(for: tabId)
        #expect(ObjectIdentifier(first) == ObjectIdentifier(second))
    }

    @Test("setBuffer(_:for:) replaces the buffer for a tab id")
    func setBufferReplacesEntry() {
        let store = RowDataStore()
        let tabId = UUID()

        let original = store.buffer(for: tabId)
        let replacement = RowBuffer(rows: [["a"]], columns: ["c"])
        store.setBuffer(replacement, for: tabId)

        let resolved = store.buffer(for: tabId)
        #expect(ObjectIdentifier(resolved) == ObjectIdentifier(replacement))
        #expect(ObjectIdentifier(resolved) != ObjectIdentifier(original))
    }

    @Test("existingBuffer(for:) returns nil before storage and the stored buffer afterwards")
    func existingBufferReflectsState() {
        let store = RowDataStore()
        let tabId = UUID()

        #expect(store.existingBuffer(for: tabId) == nil)

        let buffer = RowBuffer(rows: [["x"]], columns: ["c"])
        store.setBuffer(buffer, for: tabId)

        let resolved = store.existingBuffer(for: tabId)
        #expect(resolved != nil)
        #expect(resolved.map(ObjectIdentifier.init) == ObjectIdentifier(buffer))
    }

    @Test("removeBuffer(for:) deletes the entry")
    func removeBufferDeletes() {
        let store = RowDataStore()
        let tabId = UUID()

        store.setBuffer(RowBuffer(rows: [["x"]], columns: ["c"]), for: tabId)
        #expect(store.existingBuffer(for: tabId) != nil)

        store.removeBuffer(for: tabId)
        #expect(store.existingBuffer(for: tabId) == nil)
    }

    @Test("evict(for:) calls evict on the stored buffer")
    func evictMarksBuffer() {
        let store = RowDataStore()
        let tabId = UUID()
        let buffer = RowBuffer(rows: [["a"], ["b"]], columns: ["c"])
        store.setBuffer(buffer, for: tabId)

        #expect(buffer.isEvicted == false)
        store.evict(for: tabId)

        #expect(buffer.isEvicted == true)
        #expect(buffer.rows.isEmpty)
    }

    @Test("evict(for:) is a no-op for unknown tab ids")
    func evictUnknownTabIsNoOp() {
        let store = RowDataStore()
        store.evict(for: UUID())
    }

    @Test("evictAll(except:) evicts every other tab and spares the active one")
    func evictAllSparesActive() {
        let store = RowDataStore()
        let activeId = UUID()
        let otherId1 = UUID()
        let otherId2 = UUID()

        let activeBuffer = RowBuffer(rows: [["a"]], columns: ["c"])
        let otherBuffer1 = RowBuffer(rows: [["b"]], columns: ["c"])
        let otherBuffer2 = RowBuffer(rows: [["d"]], columns: ["c"])

        store.setBuffer(activeBuffer, for: activeId)
        store.setBuffer(otherBuffer1, for: otherId1)
        store.setBuffer(otherBuffer2, for: otherId2)

        store.evictAll(except: activeId)

        #expect(activeBuffer.isEvicted == false)
        #expect(activeBuffer.rows.count == 1)
        #expect(otherBuffer1.isEvicted == true)
        #expect(otherBuffer1.rows.isEmpty)
        #expect(otherBuffer2.isEvicted == true)
        #expect(otherBuffer2.rows.isEmpty)
    }

    @Test("evictAll(except: nil) evicts every loaded tab")
    func evictAllNoActiveEvictsAll() {
        let store = RowDataStore()
        let buffer1 = RowBuffer(rows: [["a"]], columns: ["c"])
        let buffer2 = RowBuffer(rows: [["b"]], columns: ["c"])
        store.setBuffer(buffer1, for: UUID())
        store.setBuffer(buffer2, for: UUID())

        store.evictAll(except: nil)

        #expect(buffer1.isEvicted == true)
        #expect(buffer2.isEvicted == true)
    }

    @Test("evictAll(except:) skips empty buffers")
    func evictAllSkipsEmpty() {
        let store = RowDataStore()
        let emptyBuffer = RowBuffer()
        store.setBuffer(emptyBuffer, for: UUID())

        store.evictAll(except: nil)
        #expect(emptyBuffer.isEvicted == false)
    }

    @Test("tearDown() clears the store")
    func tearDownClearsAll() {
        let store = RowDataStore()
        let tabId1 = UUID()
        let tabId2 = UUID()
        store.setBuffer(RowBuffer(rows: [["a"]], columns: ["c"]), for: tabId1)
        store.setBuffer(RowBuffer(rows: [["b"]], columns: ["c"]), for: tabId2)

        store.tearDown()

        #expect(store.existingBuffer(for: tabId1) == nil)
        #expect(store.existingBuffer(for: tabId2) == nil)
    }
}
