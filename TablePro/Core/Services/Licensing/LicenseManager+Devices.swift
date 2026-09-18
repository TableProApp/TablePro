//
//  LicenseManager+Devices.swift
//  TablePro
//
//  The seats a license is activated on, and releasing one
//

import Foundation
import os

/// What the seat list is currently doing. Loading and failure are states of the list rather than
/// stray flags beside it, so a reload cannot leave a stale error sitting above a list that has
/// since loaded.
///
/// `.loading` means there is nothing to show yet. A reload of a list that already loaded stays
/// `.loaded` and raises `isRefreshing` instead, because a refresh must never blank the content it
/// is refreshing, and a failed refresh must not replace content that is still perfectly good.
internal enum LicenseDeviceListState: Equatable {
    case idle
    case loading
    case loaded
    case failed(String)

    var isLoading: Bool { self == .loading }

    var hasContent: Bool { self == .loaded }

    var errorMessage: String? {
        guard case .failed(let message) = self else { return nil }
        return message
    }
}

extension LicenseManager {
    /// This Mac's identifier, so a row can say which seat is the one you are sitting at.
    var currentMachineId: String { LicenseStorage.shared.machineId }

    /// Whether releasing a seat other than this Mac's is offered.
    ///
    /// Only on a license with nobody else on it. The server checks a license key and a machine id
    /// and nothing else, so on a Team license every member could release every teammate and a
    /// client-side role check would not be a boundary, only a hidden button. Team seats are managed
    /// on the web until the server scopes the endpoint by caller.
    var canReleaseOtherDevices: Bool {
        guard let license else { return false }
        return !license.isTeamLicense
    }

    /// Load the seats this license is activated on.
    ///
    /// Settings panes are built once at launch and kept for the app's lifetime, so a bare `.task`
    /// refires every time the tab is reselected. `force` is what the Refresh button passes; an
    /// appearance passes false and is answered from what is already loaded.
    func loadDevices(force: Bool = false) async {
        guard let license else { return }
        guard force || deviceListState == .idle else { return }

        releaseErrorMessage = nil
        refreshErrorMessage = nil
        if deviceListState.hasContent {
            isRefreshingDevices = true
        } else {
            deviceListState = .loading
        }
        defer { isRefreshingDevices = false }

        do {
            let response = try await LicenseAPIClient.shared.listActivations(
                licenseKey: license.key,
                machineId: currentMachineId
            )
            devices = response.activations
            maxDevices = response.maxActivations
            deviceListState = .loaded
        } catch {
            /// A cancelled load is not an outcome. Recording it as `.failed` also latched the
            /// appearance guard, so the pane that cancelled its own `.task` could never retry and
            /// sat on an error nobody caused.
            guard !Self.isCancellation(error) else {
                if !deviceListState.hasContent { deviceListState = .idle }
                return
            }

            let message = (error as? LicenseError)?.friendlyDescription ?? error.localizedDescription
            Self.deviceLogger.warning("Failed to load activations: \(error.localizedDescription)")
            /// A refresh that could not reach the server leaves the seats already on screen alone
            /// and reports beside them. Only a list with nothing in it becomes an error.
            if deviceListState.hasContent {
                refreshErrorMessage = message
            } else {
                deviceListState = .failed(message)
            }
        }
    }

    /// Release one seat, then reconcile the list.
    ///
    /// A failed release restores nothing because nothing was removed optimistically: the row goes
    /// only once the server has agreed, so a failure leaves the list exactly as it was, with the
    /// reason attached.
    func releaseDevice(_ device: LicenseActivationInfo) async {
        guard license != nil else { return }
        let isThisMac = device.machineId == currentMachineId

        releasingMachineIds.insert(device.machineId)
        releaseErrorMessage = nil
        defer { releasingMachineIds.remove(device.machineId) }

        let reachedServer: Bool
        do {
            reachedServer = try await releaseSeat(machineId: device.machineId)
        } catch {
            /// Reported beside the list rather than written into `deviceListState`, which would
            /// swap a list that loaded fine for an error row and lose every other seat because one
            /// of them could not be released.
            releaseErrorMessage = (error as? LicenseError)?.friendlyDescription ?? error.localizedDescription
            return
        }

        /// `deactivate` clears this Mac's license whether or not the server agreed, so a silent
        /// success would tell somebody their seat was freed while the server still holds it, and
        /// their next activation would fail on the seat limit. The message is set after the reset,
        /// which clears it, so it survives into the state the pane lands in.
        let serverHeldTheSeat = !reachedServer

        guard !isThisMac else {
            resetDeviceList()
            if serverHeldTheSeat {
                releaseErrorMessage = Self.unreachableServerSeatMessage
            }
            return
        }

        devices.removeAll { $0.machineId == device.machineId }
        deviceListState = .loaded
    }

    /// Whether an error is the caller's own cancellation rather than something the server said.
    nonisolated static func isCancellation(_ error: Error) -> Bool {
        if error is CancellationError { return true }
        if case .networkError(let underlying)? = error as? LicenseError,
           (underlying as? URLError)?.code == .cancelled {
            return true
        }
        return (error as? URLError)?.code == .cancelled
    }

    /// Said whenever a seat was given up locally but the server never confirmed it.
    static var unreachableServerSeatMessage: String {
        String(
            localized: "The license server could not be reached, so that seat may stay in use until it expires."
        )
    }

    /// Bring the license and its seat list back in step with the server.
    ///
    /// Validation and the seat list are two calls but one question, so one control runs both.
    /// Validation goes first because it restamps this Mac's row, which the reload then reads.
    func refreshLicenseAndDevices() async {
        await revalidate()
        await loadDevices(force: true)
        await loadTeam(force: true)
    }

    func resetDeviceList() {
        devices = []
        maxDevices = 0
        releasingMachineIds = []
        releaseErrorMessage = nil
        refreshErrorMessage = nil
        deviceListState = .idle
    }
}
