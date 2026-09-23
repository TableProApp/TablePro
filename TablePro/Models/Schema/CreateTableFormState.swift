//
//  CreateTableFormState.swift
//  TablePro
//

import Foundation
import TableProPluginKit

internal struct CreateTableFormState: Equatable, Sendable {
    internal struct Entry: Identifiable, Equatable, Sendable {
        internal let id: UUID
        internal fileprivate(set) var values: [String: String]
    }

    internal enum Location: Hashable, Sendable {
        case topLevel
        case entry(sectionId: String, entryId: UUID)
    }

    internal let spec: PluginCreateTableFormSpec
    internal private(set) var values: [String: String]
    internal private(set) var submissionError: PluginCreateTableFormError?
    private var entriesBySection: [String: [Entry]] = [:]

    internal init(spec: PluginCreateTableFormSpec) {
        self.spec = spec
        self.values = Self.initialValues(of: spec.sections.filter { !$0.isRepeating }.flatMap(\.fields))
    }

    internal var holdsWork: Bool {
        values != Self.initialValues(of: topLevelFields) || entriesBySection.values.contains { !$0.isEmpty }
    }

    internal var topLevelFields: [PluginFormField] {
        spec.sections.filter { !$0.isRepeating }.flatMap(\.fields)
    }

    internal func section(withId sectionId: String) -> PluginFormSection? {
        spec.sections.first { $0.id == sectionId }
    }

    internal func entries(in sectionId: String) -> [Entry] {
        entriesBySection[sectionId] ?? []
    }

    internal func canAddEntry(to sectionId: String) -> Bool {
        guard let section = section(withId: sectionId), section.isRepeating else { return false }
        guard let maximumCount = section.maximumCount else { return true }
        return entries(in: sectionId).count < maximumCount
    }

    @discardableResult
    internal mutating func addEntry(to sectionId: String) -> UUID? {
        guard canAddEntry(to: sectionId), let section = section(withId: sectionId) else { return nil }
        let entry = Entry(id: UUID(), values: Self.initialValues(of: section.fields))
        entriesBySection[sectionId, default: []].append(entry)
        submissionError = nil
        return entry.id
    }

    internal mutating func removeEntry(_ entryId: UUID, from sectionId: String) {
        guard entries(in: sectionId).contains(where: { $0.id == entryId }) else { return }
        entriesBySection[sectionId]?.removeAll { $0.id == entryId }
        submissionError = nil
    }

    internal func value(of fieldId: String, at location: Location) -> String {
        scopeValues(at: location)[fieldId] ?? ""
    }

    internal mutating func setValue(_ value: String, of fieldId: String, at location: Location) {
        guard self.value(of: fieldId, at: location) != value else { return }
        switch location {
        case .topLevel:
            values[fieldId] = value
        case .entry(let sectionId, let entryId):
            guard let index = entries(in: sectionId).firstIndex(where: { $0.id == entryId }) else { return }
            entriesBySection[sectionId]?[index].values[fieldId] = value
        }
        submissionError = nil
    }

    internal mutating func recordSubmissionError(_ error: PluginCreateTableFormError) {
        submissionError = error
    }

    internal mutating func clearSubmissionError() {
        submissionError = nil
    }

    internal func isVisible(_ field: PluginFormField, at location: Location) -> Bool {
        isVisible(field, among: fields(at: location), values: scopeValues(at: location), visited: [])
    }

    internal func visibleFields(in section: PluginFormSection, at location: Location) -> [PluginFormField] {
        section.fields.filter { isVisible($0, at: location) }
    }

    internal func request(tableName: String) -> PluginCreateTableRequest {
        let topLevel = topLevelFields.filter { isVisible($0, at: .topLevel) }
        var repeated: [String: [[String: String]]] = [:]
        for section in spec.sections where section.isRepeating {
            repeated[section.id] = entries(in: section.id).map { entry in
                let location = Location.entry(sectionId: section.id, entryId: entry.id)
                return Self.submittedValues(of: visibleFields(in: section, at: location), from: entry.values)
            }
        }
        return PluginCreateTableRequest(
            tableName: tableName.trimmingCharacters(in: .whitespaces),
            values: Self.submittedValues(of: topLevel, from: values),
            repeatedValues: repeated
        )
    }

    internal func fields(at location: Location) -> [PluginFormField] {
        switch location {
        case .topLevel:
            return topLevelFields
        case .entry(let sectionId, _):
            return section(withId: sectionId)?.fields ?? []
        }
    }

    private func scopeValues(at location: Location) -> [String: String] {
        switch location {
        case .topLevel:
            return values
        case .entry(let sectionId, let entryId):
            return entries(in: sectionId).first { $0.id == entryId }?.values ?? [:]
        }
    }

    private func isVisible(
        _ field: PluginFormField,
        among fields: [PluginFormField],
        values: [String: String],
        visited: Set<String>
    ) -> Bool {
        guard let condition = field.visibleWhen else { return true }
        guard condition.isSatisfied(by: values) else { return false }
        guard !visited.contains(field.id),
              let controllingField = fields.first(where: { $0.id == condition.fieldId }) else { return true }
        return isVisible(controllingField, among: fields, values: values, visited: visited.union([field.id]))
    }

    private static func initialValues(of fields: [PluginFormField]) -> [String: String] {
        Dictionary(fields.map { ($0.id, $0.initialValue) }, uniquingKeysWith: { first, _ in first })
    }

    private static func submittedValues(
        of fields: [PluginFormField],
        from values: [String: String]
    ) -> [String: String] {
        Dictionary(fields.map { ($0.id, values[$0.id] ?? "") }, uniquingKeysWith: { first, _ in first })
    }
}
