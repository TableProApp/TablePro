//
//  AccountRemovalFlow.swift
//  TablePro
//

import Combine
import Foundation
import TableProFFI

// Removing a lost device after its row is gone (core ADR 0056, Removing a device, steps 2 to 4): the recovery key, the
// review of devices to keep and teammates to remove, the portal for the seats of those removed, since membership
// changes only there, then the rotation, which leaves them out whatever the server still lists.
@MainActor
internal final class AccountRemovalFlow: ObservableObject, Identifiable {
    enum Step: Equatable {
        case enterKey
        case review
        case seats
        case done
    }

    struct Team: Identifiable, Equatable {
        // The `team_` id, which the portal's team page takes too.
        let id: String
        let name: String?
    }

    struct MemberGroup: Identifiable {
        let team: Team
        let members: [AccountRemovalReview.Member]

        var id: String { team.id }
    }

    let id = UUID()
    let lost: AccountDeviceInfo
    @Published private(set) var step = Step.enterKey
    @Published private(set) var isWorking = false
    @Published private(set) var failure: String?
    @Published var recoveryKey = ""
    @Published private(set) var review: AccountRemovalReview?
    @Published private(set) var keep: Set<String> = []
    @Published private(set) var removing: Set<String> = []
    // The teammates as the review stood when the person left it, which the seats step and the rotation both use.
    @Published private(set) var submitted: Set<String> = []

    private let flows: @MainActor () async throws -> any AccountKeyFlows
    private let portal: @MainActor () -> AccountPortal
    private let openURL: @MainActor (URL) -> Void
    private var closed = false

    init(
        lost: AccountDeviceInfo,
        flows: @escaping @MainActor () async throws -> any AccountKeyFlows,
        portal: @escaping @MainActor () -> AccountPortal,
        openURL: @escaping @MainActor (URL) -> Void
    ) {
        self.lost = lost
        self.flows = flows
        self.portal = portal
        self.openURL = openURL
    }

    var deviceName: String {
        AccountKeysText.deviceName(lost.name)
    }

    var canContinue: Bool {
        guard !isWorking else { return false }
        switch step {
        case .enterKey: return !recoveryKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        case .review: return review != nil
        case .seats, .done: return true
        }
    }

    // Only a device this Mac compared words with can keep its keys; every other one joins again by approval.
    func canKeep(_ device: ReviewedDeviceInfo) -> Bool {
        device.device.compared && !device.device.thisDevice && device.device.keyDevice != lost.keyDevice
    }

    func setKeep(_ device: ReviewedDeviceInfo, _ kept: Bool) {
        guard step == .review, !isWorking, canKeep(device) else { return }
        if kept {
            keep.insert(device.device.keyDevice)
        } else {
            keep.remove(device.device.keyDevice)
        }
    }

    func setRemoving(_ member: AccountRemovalReview.Member, _ removes: Bool) {
        guard step == .review, !isWorking else { return }
        if removes {
            removing.insert(member.id)
        } else {
            removing.remove(member.id)
        }
    }

    // The review's teams in the order it listed them, each with the members it confirmed.
    var memberGroups: [MemberGroup] {
        guard let review else { return [] }
        var order: [String] = []
        var grouped: [String: [AccountRemovalReview.Member]] = [:]
        for member in review.members {
            if grouped[member.team] == nil {
                order.append(member.team)
            }
            grouped[member.team, default: []].append(member)
        }
        return order.compactMap { team in
            guard let members = grouped[team], let first = members.first else { return nil }
            return MemberGroup(team: Team(id: team, name: first.teamName), members: members)
        }
    }

    // The teams whose seats the person removes in the portal, for the members marked.
    var teamsToVisit: [Team] {
        memberGroups
            .filter { group in group.members.contains { submitted.contains($0.id) } }
            .map { $0.team }
    }

    func advance() async {
        guard canContinue else { return }
        failure = nil
        switch step {
        case .enterKey:
            await beginReview()
        case .review:
            submitted = removing
            if submitted.isEmpty {
                await finish()
            } else {
                step = .seats
            }
        case .seats:
            await finish()
        case .done:
            break
        }
    }

    // From the seats step, before anything rotated.
    func backToReview() {
        guard step == .seats, !isWorking else { return }
        failure = nil
        step = .review
    }

    func openTeam(_ team: Team) {
        openURL(portal().portalTeam(team.id))
    }

    // The sheet closed: a review the rotation never took is dropped in the core too.
    func discard() {
        closed = true
        recoveryKey = ""
        if let review, step != .done {
            release(review.review)
        }
    }

    private func release(_ draft: String) {
        let flows = flows
        Task {
            try? await flows().discardKeyDraft(draft: draft)
        }
    }

    private func beginReview() async {
        let recoveryKey = recoveryKey
        await working {
            let review = AccountRemovalReview(
                try await self.flows().beginDeviceRemoval(recoveryKey: recoveryKey, lost: [self.lost.keyDevice])
            )
            guard !self.closed else {
                self.release(review.review)
                return
            }
            self.recoveryKey = ""
            self.review = review
            self.keep = Set(review.devices.filter { $0.keepByDefault && self.canKeep($0) }.map(\.device.keyDevice))
            self.removing = []
            self.step = .review
        }
    }

    private func finish() async {
        guard let review else { return }
        let keep = review.devices.map(\.device.keyDevice).filter { self.keep.contains($0) }
        let remove = review.members.filter { submitted.contains($0.id) }.map(\.record)
        await working {
            try await self.flows().finishDeviceRemoval(review: review.review, keep: keep, remove: remove)
            self.step = .done
        }
    }

    private func working(_ body: @MainActor () async throws -> Void) async {
        isWorking = true
        defer { isWorking = false }
        do {
            try await body()
        } catch {
            guard !closed else { return }
            failure = AccountKeysText.message(for: error)
        }
    }
}
