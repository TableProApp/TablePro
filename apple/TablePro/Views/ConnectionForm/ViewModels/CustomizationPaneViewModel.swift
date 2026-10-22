//
//  CustomizationPaneViewModel.swift
//  TablePro
//

import Combine
import Foundation
import TableProAutocomplete
import TableProConnectionLibrary

@MainActor
final class CustomizationPaneViewModel: ObservableObject {
    @Published var color: ConnectionColor = .none
    @Published var iconName: String?
    @Published var tagIds: [UUID] = []
    @Published var groupId: UUID?
    @Published var safeModeLevel: SafeModeLevel = .silent
    @Published var connectTimeoutSeconds: Int?
    @Published var queryTimeoutSeconds: Int?
    @Published var binaryInlineLimitKilobytes: Int?
    @Published var completionIdentifierCase: SQLIdentifierCase = .default

    @Published var coordinator: WeakCoordinatorRef?

    var validationIssues: [String] {
        var issues: [String] = []
        if let connectTimeoutSeconds,
           !ConnectionTimeoutPolicy.connectTimeoutRange.contains(connectTimeoutSeconds)
        {
            issues.append(String(localized: "Connect timeout must be between 1 and 600 seconds."))
        }
        if let queryTimeoutSeconds,
           !DatabaseConnection.queryTimeoutSecondsRange.contains(queryTimeoutSeconds)
        {
            issues.append(String(localized: "Query timeout must be between 0 and 2,147,483 seconds."))
        }
        if let binaryInlineLimitKilobytes,
           !DatabaseConnection.binaryInlineLimitKilobytesRange.contains(binaryInlineLimitKilobytes)
        {
            issues.append(String(localized: "Binary values limit must be between 1 and 1,048,576 KB."))
        }
        return issues
    }

    func load(from connection: DatabaseConnection) {
        color = connection.color
        iconName = LibrarySymbolCatalog.normalizedName(connection.iconName)
        tagIds = connection.tagIds
        groupId = connection.groupId
        safeModeLevel = connection.preferredSafeModeLevel
        connectTimeoutSeconds = connection.connectTimeoutSeconds
        queryTimeoutSeconds = connection.queryTimeoutSeconds
        binaryInlineLimitKilobytes = connection.binaryInlineLimitKilobytes
        completionIdentifierCase = connection.completionIdentifierCase
    }
}
