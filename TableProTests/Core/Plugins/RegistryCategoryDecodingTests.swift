//
//  RegistryCategoryDecodingTests.swift
//  TableProTests
//

import Foundation
@testable import TablePro
import Testing

struct RegistryCategoryDecodingTests {
    @Test("An entry with a category this app does not know decodes as other, and the rest still load")
    func unknownCategoryDecodesAsOther() throws {
        let json = """
        {"schemaVersion": 2, "plugins": [
            {"id": "com.example.theme", "name": "Theme", "version": "1.0.0", "summary": "test",
             "author": {"name": "Tester"}, "category": "theme", "binaries": []},
            {"id": "com.example.driver", "name": "Driver", "version": "1.0.0", "summary": "test",
             "author": {"name": "Tester"}, "category": "database-driver", "binaries": []}
        ]}
        """
        let manifest = try JSONDecoder().decode(RegistryManifest.self, from: Data(json.utf8))

        #expect(manifest.plugins.map(\.category) == [.other, .databaseDriver])
    }
}
