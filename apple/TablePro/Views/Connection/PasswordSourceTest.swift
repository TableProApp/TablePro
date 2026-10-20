//
//  PasswordSourceTest.swift
//  TablePro
//

import Combine
import SwiftUI

@MainActor
final class PasswordSourceTestModel: ObservableObject {
    enum Outcome: Equatable {
        case returned(String)
        case failed(String)
    }

    @Published private(set) var isRunning = false
    @Published private var latest: (source: PasswordSource, environment: [String: String], outcome: Outcome)?

    private let resolve: @Sendable (PasswordSource, ConnectionScriptContext) async throws -> String

    init(
        resolve: @escaping @Sendable (PasswordSource, ConnectionScriptContext) async throws -> String = { source, context in
            try await PasswordSourceResolver.test(source, for: context)
        }
    ) {
        self.resolve = resolve
    }

    // A result describes the source and connection details it ran with; after an edit to either it is about something else.
    func outcome(for source: PasswordSource, context: @autoclosure () -> ConnectionScriptContext) -> Outcome? {
        guard let latest, latest.source == source, latest.environment == context().environment else { return nil }
        return latest.outcome
    }

    func run(_ source: PasswordSource, context: ConnectionScriptContext, refusal: (any Error)?) async {
        guard !isRunning else { return }
        if let refusal {
            latest = (source, context.environment, .failed(refusal.localizedDescription))
            return
        }
        isRunning = true
        defer { isRunning = false }
        do {
            let value = try await resolve(source, context)
            latest = (source, context.environment, .returned(value))
        } catch {
            latest = (source, context.environment, .failed(error.localizedDescription))
        }
    }
}

struct PasswordSourceTestView: View {
    let source: PasswordSource
    let context: () -> ConnectionScriptContext
    let refusal: () -> (any Error)?

    @StateObject private var model = PasswordSourceTestModel()
    @StateObject private var reveal = SecretReveal()

    var body: some View {
        HStack {
            Button(String(localized: "Test Source")) {
                let context = context()
                let refusal = refusal()
                Task { await model.run(source, context: context, refusal: refusal) }
            }
            .disabled(model.isRunning)
            .accessibilityIdentifier("password-source-test")
            if model.isRunning {
                ProgressView()
                    .controlSize(.small)
            }
        }
        switch model.outcome(for: source, context: context()) {
        case .returned(let value):
            LabeledContent(String(localized: "Result")) {
                if reveal.isRevealed {
                    Text(value)
                        .font(.body.monospaced())
                        .textSelection(.enabled)
                        .lineLimit(4)
                } else {
                    Text(Self.masked(value))
                        .accessibilityLabel(String(localized: "Hidden"))
                }
            }
            SecretRevealToggle(reveal: reveal, requiresAuthentication: true)
        case .failed(let message):
            Label(message, systemImage: "exclamationmark.triangle.fill")
                .font(.caption)
                .foregroundStyle(.red)
                .textSelection(.enabled)
        case nil:
            EmptyView()
        }
    }

    static func masked(_ value: String) -> String {
        String(repeating: "\u{2022}", count: min(value.count, 24))
    }
}

struct PasswordSourceSummary: View {
    let title: String
    let source: PasswordSource

    private var parts: (kind: PasswordSourceKind, value: String, field: String) {
        PasswordSourceKind.decompose(source)
    }

    var body: some View {
        LabeledContent(title, value: parts.kind.displayName)
        LabeledContent(parts.kind.valueLabel) {
            Text(parts.value)
                .font(.body.monospaced())
                .textSelection(.enabled)
                .lineLimit(3)
                .truncationMode(.middle)
        }
        if let fieldLabel = parts.kind.fieldLabel, !parts.field.isEmpty {
            LabeledContent(fieldLabel, value: parts.field)
        }
        Text("Set in connections.json.")
            .font(.caption)
            .foregroundStyle(.secondary)
    }
}
