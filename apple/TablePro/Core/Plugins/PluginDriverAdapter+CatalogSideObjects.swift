//
//  PluginDriverAdapter+CatalogSideObjects.swift
//  TablePro
//

import Foundation
import os
import TableProPluginKit

extension PluginDriverAdapter {
    private static let sideObjectsLogger = Logger(subsystem: "com.TablePro", category: "PluginDriverAdapter")

    // One call to the plugin, whose engine may answer every kind in one round trip. Each answer is stamped and sorted
    // as the kind's own fetch does it, so a load and a single-kind reload commit the same lists.
    func fetchCatalogSideObjects(_ request: CatalogSideRequest) async -> CatalogSideObjects {
        let resolvedSchema = readSchema(request.schema)
        let answers = await pluginDriver.fetchCatalogSideObjects(PluginCatalogSideRequest(
            schema: resolvedSchema,
            schemas: request.schemas,
            routines: request.routines,
            triggers: request.triggers,
            userDefinedTypes: request.userDefinedTypes,
            serverObjectKinds: request.serverObjectKinds
        ))
        var objects = CatalogSideObjects()
        objects.schemas = answers.schemas.map { logged($0, kind: "schemas") }
        objects.routines = answers.routines.map { answer in
            logged(answer, kind: "routines").map { routines in
                routines.map { RoutineInfo($0.adopting(kind: $0.kind, schema: resolvedSchema)) }
                    .sorted { ($0.kind.rawValue, $0.name) < ($1.kind.rawValue, $1.name) }
            }
        }
        objects.triggers = answers.triggers.map { answer in
            logged(answer, kind: "triggers").map { triggers in
                triggers.map { TriggerInfo($0.adopting(table: nil, schema: resolvedSchema)) }
            }
        }
        objects.userDefinedTypes = answers.userDefinedTypes.map { answer in
            logged(answer, kind: "types").map { types in
                types.map { UserDefinedTypeInfo($0.adoptingSchema(resolvedSchema)) }.sorted { $0.name < $1.name }
            }
        }
        for kindId in request.serverObjectKinds {
            guard let answer = answers.serverObjects[kindId] else { continue }
            let isDatabaseScoped = pluginDriver.serverObjectKinds.first { $0.id == kindId }?.scope == .database
            let kindSchema = isDatabaseScoped ? nil : resolvedSchema
            objects.serverObjects[kindId] = logged(answer, kind: "server objects").map { listed in
                listed.filter { $0.kindId == kindId }
                    .map { ServerObjectInfo($0).adoptingSchema(kindSchema) }
                    .sorted { ($0.schema ?? "", $0.name) < ($1.schema ?? "", $1.name) }
            }
        }
        return objects
    }

    private func logged<T>(_ answer: Result<T, any Error>, kind: String) -> Result<T, any Error> {
        if case .failure(let error) = answer {
            Self.sideObjectsLogger.warning(
                "fetchCatalogSideObjects failed kind=\(kind, privacy: .public) error=\(error.publicLogShape, privacy: .public)"
            )
        }
        return answer
    }
}
