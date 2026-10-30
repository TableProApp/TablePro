//
//  RoutineDebugTabView.swift
//  TablePro
//

import SwiftUI
import TableProPluginKit

// The call stack beside the source, and under them Xcode's debug area: its bar of controls and status, then variables beside the output.
// Nested split views first lay out at their minimums, before the window gives them room, so holding priorities, not
// thickness fractions, decide the layout: the source takes the room, the debug area and the stack keep their size, and
// variables and output share theirs.
internal struct RoutineDebugTabView: View {
    @ObservedObject var controller: RoutineDebugController
    let databaseType: DatabaseType

    var body: some View {
        AutosavingSplitView(
            autosaveName: "com.TablePro.routineDebug.sourceAndPanes",
            isVertical: false,
            primaryMinimum: 160,
            secondaryMinimum: 200,
            primaryHoldingPriority: .splitPaneFlexible
        ) {
            AutosavingSplitView(
                autosaveName: "com.TablePro.routineDebug.stackAndSource",
                primaryMinimum: 200,
                secondaryMinimum: 280
            ) {
                RoutineDebugCallStackView(controller: controller)
            } secondary: {
                RoutineDebugSourceView(controller: controller, databaseType: databaseType)
            }
        } secondary: {
            VStack(spacing: 0) {
                RoutineDebugBar(controller: controller)
                Divider()
                AutosavingSplitView(
                    autosaveName: "com.TablePro.routineDebug.variablesAndOutput",
                    primaryMinimum: 220,
                    secondaryMinimum: 220,
                    primaryHoldingPriority: .defaultLow
                ) {
                    RoutineDebugVariablesView(controller: controller)
                } secondary: {
                    RoutineDebugOutputView(controller: controller)
                }
            }
        }
    }
}

// The Debug menu's commands as one-click controls, with the run's status beside them.
internal struct RoutineDebugBar: View {
    @ObservedObject var controller: RoutineDebugController

    var body: some View {
        HStack(spacing: 12) {
            HStack(spacing: 2) {
                command(.continueExecution, title: String(localized: "Continue"), symbol: "play")
                command(.stepOver, title: String(localized: "Step Over"), symbol: "arrow.uturn.forward")
                command(.stepInto, title: String(localized: "Step Into"), symbol: "arrow.down.to.line")
                command(.stepOut, title: String(localized: "Step Out"), symbol: "arrow.up.to.line")
                Button {
                    controller.stop()
                } label: {
                    Label(String(localized: "Stop"), systemImage: "stop")
                }
                .help(String(localized: "Stop Debugging"))
                .disabled(!controller.canStop)
            }
            .labelStyle(.iconOnly)
            .buttonStyle(.borderless)

            Divider()
                .frame(height: 16)

            statusIcon
            Text(controller.statusText)
                .lineLimit(1)
                .truncationMode(.tail)
                .help(controller.statusText)
                .accessibilityIdentifier("routine-debug-status")
            if let error = controller.inspectionError {
                Text(error)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .help(error)
            }
            Spacer(minLength: 0)
        }
        .font(.callout)
        .padding(.horizontal, 10)
        .frame(height: 28)
        .paneBarBackground()
    }

    private func command(_ command: PluginDebugCommand, title: String, symbol: String) -> some View {
        Button {
            controller.perform(command)
        } label: {
            Label(title, systemImage: symbol)
        }
        .help(title)
        .disabled(!controller.canPerform(command))
    }

    @ViewBuilder
    private var statusIcon: some View {
        switch controller.state {
        case .preparing, .starting, .running:
            ProgressView()
                .controlSize(.small)
        case .paused:
            Image(systemName: "pause.circle")
                .foregroundStyle(.secondary)
        case .finished:
            Image(systemName: "checkmark.circle")
                .foregroundStyle(.secondary)
        case .failed:
            Image(systemName: "exclamationmark.triangle")
                .foregroundStyle(.secondary)
        case .stopped:
            Image(systemName: "stop.circle")
                .foregroundStyle(.secondary)
        }
    }
}

// A debug tab exists only with a live controller, so a tab that has none says so rather than drawing empty panes.
internal struct RoutineDebugTabContent: View {
    let tabId: UUID
    let databaseType: DatabaseType

    var body: some View {
        if let controller = RoutineDebugSessions.shared.controller(forTab: tabId) {
            RoutineDebugTabView(controller: controller, databaseType: databaseType)
        } else {
            UnavailableStateView(String(localized: "Debug Session Ended"), systemImage: "ladybug")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}
