//
//  LicenseDeviceListStateTests.swift
//  TableProTests
//

import Foundation
import Testing

@testable import TablePro

@Suite("LicenseDeviceListState")
struct LicenseDeviceListStateTests {
    @Test("A failure carries its reason, and no other state pretends to have one")
    func onlyFailureCarriesAMessage() {
        #expect(LicenseDeviceListState.failed("offline").errorMessage == "offline")
        #expect(LicenseDeviceListState.idle.errorMessage == nil)
        #expect(LicenseDeviceListState.loading.errorMessage == nil)
        #expect(LicenseDeviceListState.loaded.errorMessage == nil)
    }

    /// The old pane kept its error in a separate `@State` that nothing ever reset, so a network
    /// blip pinned a red line above a list that had since loaded. Making the error a state of the
    /// list rather than a flag beside it is what stops that returning.
    @Test("Reaching a loaded state leaves no error behind it")
    func loadingClearsAPreviousFailure() {
        var state = LicenseDeviceListState.failed("The request timed out.")
        #expect(state.errorMessage != nil)

        state = .loading
        #expect(state.errorMessage == nil)

        state = .loaded
        #expect(state.errorMessage == nil)
    }

    @Test("Only the loading state reports itself as loading")
    func isLoadingIsExact() {
        #expect(LicenseDeviceListState.loading.isLoading)
        #expect(LicenseDeviceListState.idle.isLoading == false)
        #expect(LicenseDeviceListState.loaded.isLoading == false)
        #expect(LicenseDeviceListState.failed("x").isLoading == false)
    }
}

@Suite("LicenseManager unlicensed status")
struct LicenseManagerUnlicensedStatusTests {
    /// `deactivate()` used to assign `.deactivated` straight onto `status`, which skipped the only
    /// place that publishes a change, so iCloud Sync went on reporting a healthy sync for a licence
    /// that no longer existed. Routing it through the status resolver is what fires the
    /// notification, and this pins the distinction the resolver has to keep.
    @Test("Giving up a seat here is not the same as never having had one")
    func deactivatedIsDistinctFromUnlicensed() {
        #expect(LicenseManager.resolveUnlicensedStatus(wasDeactivatedLocally: true) == .deactivated)
        #expect(LicenseManager.resolveUnlicensedStatus(wasDeactivatedLocally: false) == .unlicensed)
    }

    @Test("Neither outcome counts as a valid license")
    func neitherIsValid() {
        #expect(LicenseManager.resolveUnlicensedStatus(wasDeactivatedLocally: true).isValid == false)
        #expect(LicenseManager.resolveUnlicensedStatus(wasDeactivatedLocally: false).isValid == false)
    }
}
