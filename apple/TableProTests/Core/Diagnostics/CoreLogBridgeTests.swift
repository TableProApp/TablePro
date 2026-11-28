//
//  CoreLogBridgeTests.swift
//  TableProTests
//

import Foundation
import os
@testable import TablePro
import TableProFFI
import Testing

struct CoreLogBridgeTests {
    private static func line(
        _ level: CoreLogLevel = .info,
        target: String = "tablepro_sync::engine::held",
        message: String = "event core/crates/sync/src/engine/held.rs:50",
        public publicFields: [(String, String)] = [],
        private privateFields: [(String, String)] = []
    ) -> CoreLogLine {
        CoreLogLine(
            level: level,
            target: target,
            message: message,
            publicFields: publicFields.map { CoreLogField(name: $0.0, value: $0.1) },
            privateFields: privateFields.map { CoreLogField(name: $0.0, value: $0.1) }
        )
    }

    @Test("A private field, the event's own text included, never reaches the public part of the line")
    func privateFieldStaysPrivate() {
        let rendered = CoreLogBridge.render(Self.line(
            public: [("kind", "connection"), ("count", "2")],
            private: [
                ("message", "held for approval: Orders Production"),
                ("record", "7E1D4C2A-8B0F-4A55-9C1E-2B6D3F4A5B6C"),
                ("host", "db.example.com")
            ]
        ))

        #expect(rendered.publicText == "event core/crates/sync/src/engine/held.rs:50 kind=connection count=2")
        for secret in ["held for approval", "Orders Production", "7E1D4C2A", "db.example.com"] {
            #expect(!rendered.publicText.contains(secret))
        }
        #expect(
            rendered.privateText
                == "message=held for approval: Orders Production record=7E1D4C2A-8B0F-4A55-9C1E-2B6D3F4A5B6C host=db.example.com"
        )
    }

    @Test("A field sent as public under a name outside the core's list goes private")
    func unknownPublicNameGoesPrivate() {
        let rendered = CoreLogBridge.render(Self.line(public: [("code", "sync.changed"), ("host", "db.example.com")]))

        #expect(rendered.publicText == "event core/crates/sync/src/engine/held.rs:50 code=sync.changed")
        #expect(rendered.privateText == "host=db.example.com")
    }

    @Test("Each level lands at the unified log's level, and sync lines under the sync category")
    func levelsAndCategory() {
        #expect(CoreLogBridge.render(Self.line(.error)).level == .error)
        #expect(CoreLogBridge.render(Self.line(.warn)).level == .default)
        #expect(CoreLogBridge.render(Self.line(.info)).level == .info)
        #expect(CoreLogBridge.render(Self.line(.trace)).level == .debug)
        #expect(CoreLogBridge.render(Self.line()).category == "SyncEngineHost")
        #expect(CoreLogBridge.render(Self.line(target: "tablepro_storage::library")).category == "Core")
    }
}
