//
//  CreateViewEligibility.swift
//  TablePro
//

import Foundation

internal enum CreateViewEligibility {
    // The template is the engine's own CREATE VIEW; an engine without one has no views to create.
    @MainActor
    internal static func canCreateView(with driver: DatabaseDriver?) -> Bool {
        driver?.createViewTemplate() != nil
    }
}
