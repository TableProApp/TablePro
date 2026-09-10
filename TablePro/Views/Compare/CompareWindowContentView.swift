//
//  CompareWindowContentView.swift
//  TablePro
//
//  The window's body: results on the left, detail on the right.
//
//  There is no action bar under it. Compare, Generate Script and Apply live in
//  the toolbar and in the Database > Compare menu, which is where the HIG puts
//  a window's primary actions and the only place a user can reach them when the
//  window's bottom edge is off screen.
//

import SwiftUI

internal struct CompareWindowContentView: View {
    @Bindable internal var session: CompareSyncSession
    internal var onCompare: () -> Void
    internal var onGenerateScript: () -> Void
    internal var onApply: () -> Void

    internal var body: some View {
        AutosavingSplitView(
            autosaveName: "com.TablePro.CompareSync.main",
            primaryMinimum: 260,
            secondaryMinimum: 360,
            primaryThicknessFraction: 0.33,
            primaryAutomaticMaximum: 576
        ) {
            resultsPane
        } secondary: {
            CompareDetailView(
                session: session,
                onCompare: onCompare,
                onGenerateScript: onGenerateScript
            )
        }
        /// The HIG's sanctioned use of a bottom bar, and the reason this one carries no action:
        /// "use it only to display a small amount of information directly related to a window's
        /// contents... For example, Finder uses a bottom bar (called the status bar) to display the
        /// total number of items in a window, the number of selected items".
        .safeAreaInset(edge: .bottom, spacing: 0) {
            CompareStatusBar(session: session)
        }
        .frame(minWidth: 720, minHeight: 460)
    }

    @ViewBuilder
    private var resultsPane: some View {
        switch session.mode {
        case .structure:
            CompareResultsView(session: session, onCompare: onCompare)
        case .data:
            CompareDataPlansView(session: session, onCompare: onCompare)
        }
    }
}

/// The one line that says whether anything has been written, plus in-flight progress.
///
/// It sits at the top rather than the bottom for the reason the HIG gives about bottom bars, and
/// it is deliberately not an action bar: it carries state and a Cancel, never a primary action.
internal struct CompareStatusStrip: View {
    @Bindable internal var session: CompareSyncSession

    internal var body: some View {
        HStack(spacing: 12) {
            Label {
                Text(session.bannerText)
            } icon: {
                Image(systemName: symbol)
            }
            .font(.callout)

            if let target = session.target {
                Divider().frame(height: 14)
                HStack(spacing: 6) {
                    Circle()
                        .fill(target.color.indicatorColor ?? Color.secondary.opacity(0.35))
                        .frame(width: 9, height: 9)
                        .accessibilityHidden(true)
                    Text(String(format: String(localized: "Target: %@"), target.qualifiedDescription))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Spacer(minLength: 12)

            if session.isBusy {
                CompareProgressView(session: session)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .contain)
    }

    private var symbol: String {
        switch session.activity {
        case .applying: return "exclamationmark.triangle.fill"
        case .comparing, .connecting, .buildingScript: return "magnifyingglass"
        case .idle: return session.hasWrittenToTarget ? "checkmark.circle" : "eye"
        }
    }
}
