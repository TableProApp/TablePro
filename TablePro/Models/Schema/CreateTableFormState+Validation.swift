//
//  CreateTableFormState+Validation.swift
//  TablePro
//

import Foundation
import TableProPluginKit

internal extension CreateTableFormState {
    struct Issue: Equatable, Sendable {
        enum Kind: Equatable, Sendable {
            case missing
            case invalid
        }

        let kind: Kind
        let location: Location?
        let fieldId: String?
        let message: String
        let qualifiedMessage: String
    }

    enum Preview: Equatable, Sendable {
        case statements(String)
        case message(String)
    }

    func issues(tableName: String) -> [Issue] {
        var issues: [Issue] = []
        if tableName.trimmingCharacters(in: .whitespaces).isEmpty {
            let message = String(localized: "The table needs a name.")
            issues.append(Issue(kind: .missing, location: nil, fieldId: nil, message: message, qualifiedMessage: message))
        }
        return issues + fieldIssues()
    }

    func fieldIssues() -> [Issue] {
        var issues: [Issue] = []
        for section in spec.sections where !section.isRepeating {
            issues += fieldIssues(in: section, at: .topLevel, entryNumber: nil)
        }
        for section in spec.sections where section.isRepeating {
            for (offset, entry) in entries(in: section.id).enumerated() {
                let location = Location.entry(sectionId: section.id, entryId: entry.id)
                issues += fieldIssues(in: section, at: location, entryNumber: offset + 1)
            }
        }
        return issues
    }

    func inlineMessage(for fieldId: String, at location: Location) -> String? {
        if location == .topLevel, inlineSubmissionErrorFieldId == fieldId, let submissionError {
            return submissionError.message
        }
        return fieldIssues()
            .first { $0.kind == .invalid && $0.location == location && $0.fieldId == fieldId }?
            .message
    }

    var inlineSubmissionErrorFieldId: String? {
        guard let fieldId = submissionError?.fieldId else { return nil }
        let repeatingFieldIds = Set(spec.sections.filter(\.isRepeating).flatMap(\.fields).map(\.id))
        guard !repeatingFieldIds.contains(fieldId),
              let field = topLevelFields.first(where: { $0.id == fieldId }),
              isVisible(field, at: .topLevel) else { return nil }
        return fieldId
    }

    func preview(
        tableName: String,
        generate: (PluginCreateTableRequest) throws -> [String]
    ) -> Preview {
        if let issue = issues(tableName: tableName).first {
            return .message(issue.qualifiedMessage)
        }
        do {
            let statements = try generate(request(tableName: tableName))
            guard !statements.isEmpty else {
                return .message(String(localized: "The form produced no statements to run."))
            }
            return .statements(CreateTableStatements(statements: statements, issues: [], tableName: nil).preview)
        } catch let formError as PluginCreateTableFormError {
            return .message(formError.message)
        } catch {
            return .message(error.localizedDescription)
        }
    }

    static func entryTitle(number: Int) -> String {
        String(format: String(localized: "Entry %lld"), Int64(number))
    }

    private func fieldIssues(in section: PluginFormSection, at location: Location, entryNumber: Int?) -> [Issue] {
        visibleFields(in: section, at: location).compactMap { field in
            guard let problem = Self.problem(with: field, value: value(of: field.id, at: location)) else {
                return nil
            }
            return Issue(
                kind: problem.kind,
                location: location,
                fieldId: field.id,
                message: problem.message,
                qualifiedMessage: Self.qualified(problem.message, section: section, entryNumber: entryNumber)
            )
        }
    }

    private static func qualified(_ message: String, section: PluginFormSection, entryNumber: Int?) -> String {
        guard let entryNumber else { return message }
        guard let title = section.title, !title.isEmpty else {
            return String(format: String(localized: "Entry %1$lld: %2$@"), Int64(entryNumber), message)
        }
        return String(format: String(localized: "%1$@, entry %2$lld: %3$@"), title, Int64(entryNumber), message)
    }

    private static func problem(
        with field: PluginFormField,
        value: String
    ) -> (kind: Issue.Kind, message: String)? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        switch field.kind {
        case .text(_, let isRequired):
            guard isRequired, trimmed.isEmpty else { return nil }
            return (.missing, String(format: String(localized: "%@ is required."), field.label))
        case .integer(_, let minimum, let maximum):
            guard !trimmed.isEmpty else { return nil }
            guard let number = Int(trimmed) else {
                return (.invalid, String(format: String(localized: "%@ must be a whole number."), field.label))
            }
            guard let message = rangeProblem(number, minimum: minimum, maximum: maximum, label: field.label) else {
                return nil
            }
            return (.invalid, message)
        case .picker, .toggle:
            return nil
        @unknown default:
            return nil
        }
    }

    private static func rangeProblem(_ number: Int, minimum: Int?, maximum: Int?, label: String) -> String? {
        let isBelow = minimum.map { number < $0 } ?? false
        let isAbove = maximum.map { number > $0 } ?? false
        guard isBelow || isAbove else { return nil }
        if let minimum, let maximum {
            return String(
                format: String(localized: "%1$@ must be between %2$lld and %3$lld."),
                label, Int64(minimum), Int64(maximum)
            )
        }
        if let minimum {
            return String(format: String(localized: "%1$@ must be at least %2$lld."), label, Int64(minimum))
        }
        guard let maximum else { return nil }
        return String(format: String(localized: "%1$@ must be at most %2$lld."), label, Int64(maximum))
    }
}
