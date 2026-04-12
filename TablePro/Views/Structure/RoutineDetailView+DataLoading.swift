import Foundation
import os

extension RoutineDetailView {
    @MainActor
    func loadInitialData() async {
        isLoading = true
        errorMessage = nil

        guard let driver = DatabaseManager.shared.driver(for: connection.id) else {
            errorMessage = String(localized: "Not connected")
            isLoading = false
            return
        }

        do {
            definition = try await driver.fetchRoutineDefinition(routine: routineName, type: routineType)
            loadedTabs.insert(.definition)
            isLoading = false
        } catch {
            errorMessage = error.localizedDescription
            isLoading = false
        }
    }

    @MainActor
    func loadTabDataIfNeeded(_ tab: RoutineDetailTab) async {
        guard !loadedTabs.contains(tab) else { return }
        guard let driver = DatabaseManager.shared.driver(for: connection.id) else { return }

        do {
            switch tab {
            case .definition:
                definition = try await driver.fetchRoutineDefinition(routine: routineName, type: routineType)
            case .parameters:
                parameters = try await driver.fetchRoutineParameters(routine: routineName, type: routineType)
            case .ddl:
                ddlStatement = try await driver.fetchRoutineDefinition(routine: routineName, type: routineType)
            }
            loadedTabs.insert(tab)
        } catch {
            Self.logger.error("Failed to load \(tab.rawValue) for \(routineName): \(error.localizedDescription)")
        }
    }
}
