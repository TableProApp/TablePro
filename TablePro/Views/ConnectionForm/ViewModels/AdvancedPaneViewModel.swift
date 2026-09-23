//
//  AdvancedPaneViewModel.swift
//  TablePro
//

import Combine
import Foundation
import TableProPluginKit

@MainActor
final class AdvancedPaneViewModel: ObservableObject {
    @Published var additionalFieldValues: [String: String] = [:]
    @Published var startupCommands: String = ""
    @Published var preConnectScript: String = ""
    @Published var externalAccess: ExternalAccessLevel = .readOnly
    @Published var localOnly: Bool = false
    @Published var aiPolicy: AIConnectionPolicy?

    @Published var coordinator: WeakCoordinatorRef?

    /// The extensions the connection held when the form opened. Only what the person adds or changes
    /// here counts as approved on this Mac, so saving an imported connection without touching its
    /// list approves nothing.
    private(set) var initialExtensions: [LoadableExtension] = []

    var advancedFields: [ConnectionField] {
        allAdvancedFields.filter { $0.content == .plain }
    }

    /// The extension list the form shows for this type and these values, if any.
    var extensionListField: ConnectionField? {
        allAdvancedFields.first { $0.content == .loadableExtensions && isFieldVisible($0) }
    }

    var editedExtensions: [LoadableExtension] {
        let initial = Set(initialExtensions)
        return currentExtensions.filter { !initial.contains($0) }
    }

    var validationIssues: [String] {
        var issues: [String] = []
        for field in advancedFields where field.isRequired && isFieldVisible(field) {
            let value = additionalFieldValues[field.id] ?? field.defaultValue ?? ""
            if value.trimmingCharacters(in: .whitespaces).isEmpty {
                issues.append(String(format: String(localized: "%@ is required"), field.label))
            }
        }
        issues += advancedFields.filter(isFieldVisible).compactMap { $0.rangeIssue(in: additionalFieldValues[$0.id] ?? "") }
        if let extensionIssue {
            issues.append(extensionIssue)
        }
        return issues
    }

    private var allAdvancedFields: [ConnectionField] {
        guard let type = coordinator?.value?.network.type else { return [] }
        return PluginManager.shared.additionalConnectionFields(for: type)
            .filter { $0.section == .advanced }
    }

    private var currentExtensions: [LoadableExtension] {
        guard let field = extensionListField else { return [] }
        return (try? LoadableExtensionList.decode(additionalFieldValues[field.id])) ?? []
    }

    private var extensionIssue: String? {
        do {
            try LoadableExtensionPreflight.validate(currentExtensions)
            return nil
        } catch let error as LoadableExtensionError {
            return error.failureReason
        } catch {
            return error.localizedDescription
        }
    }

    func isFieldVisible(_ field: ConnectionField) -> Bool {
        let type = coordinator?.value?.network.type ?? .mysql
        let values = coordinator?.value?.allAdditionalFieldValues ?? additionalFieldValues
        return PluginFieldRendering.isFieldVisible(field, type: type, values: values)
    }

    func resetForType(_ newType: DatabaseType) {
        var values: [String: String] = [:]
        for field in PluginManager.shared.additionalConnectionFields(for: newType)
            where field.section == .advanced
        {
            if let defaultValue = field.defaultValue {
                values[field.id] = defaultValue
            }
        }
        additionalFieldValues = values
    }

    func load(from connection: DatabaseConnection) {
        var values: [String: String] = [:]
        let allFields = PluginManager.shared.additionalConnectionFields(for: connection.type)
        for field in allFields where field.section == .advanced {
            if let value = connection.additionalFields[field.id] {
                values[field.id] = value
            } else if let defaultValue = field.defaultValue {
                values[field.id] = defaultValue
            }
        }
        if allFields.contains(where: { $0.id == RedisDatabaseIndex.fieldName && $0.section == .advanced }) {
            values[RedisDatabaseIndex.fieldName] = String(connection.configuredRedisDatabaseIndex)
        }
        additionalFieldValues = values
        initialExtensions = allFields
            .filter { $0.content == .loadableExtensions }
            .flatMap { (try? LoadableExtensionList.decode(connection.additionalFields[$0.id])) ?? [] }
        startupCommands = connection.startupCommands ?? ""
        preConnectScript = connection.preConnectScript ?? ""
        aiPolicy = connection.aiPolicy
        externalAccess = connection.externalAccess
        localOnly = connection.localOnly
    }

    func write(into fields: inout [String: String]) {
        for (key, value) in additionalFieldValues {
            fields[key] = value
        }
    }
}
