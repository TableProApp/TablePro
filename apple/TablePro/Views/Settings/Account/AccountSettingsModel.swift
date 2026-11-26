import Combine
import Foundation
import TableProHTTP

internal struct AccountRemote<Value: Equatable>: Equatable {
    var value: Value?
    var isLoading = false
    var failure: String?
}

internal struct AccountActionFailure: Equatable, Identifiable {
    let title: String
    let message: String

    var id: String { title + message }
}

internal struct AccountSignOutConfirmation: Equatable {
    // The Team Library edits the team has not taken yet, read just before the question.
    let teamChanges: [String]
    var uploadFailure: TeamLibraryFailure?
    let removesOfflineFile: Bool

    var discardsSomething: Bool {
        !teamChanges.isEmpty || removesOfflineFile
    }

    var message: String {
        var sentences = [String(localized: "Paid features stop on this Mac until you sign in again.")]
        if !teamChanges.isEmpty {
            sentences.append(TeamLibraryUnsentChanges.message(teamChanges, failure: uploadFailure))
        }
        if removesOfflineFile {
            sentences.append(String(localized: "The imported offline file is removed."))
        }
        return sentences.joined(separator: " ")
    }
}

@MainActor
internal final class AccountSettingsModel: ObservableObject {
    enum Activity: Equatable {
        case signingIn
        case signingOut
        case checking
        case removing(String)
        case importing
        case usingKey
    }

    struct Loader {
        var profile: @MainActor () async throws(AccountError) -> AccountProfile
        var devices: @MainActor () async throws(AccountError) -> [AccountDevice]

        static func live(_ services: AccountServices) -> Loader {
            Loader(
                profile: { () async throws(AccountError) -> AccountProfile in try await services.fetchProfile() },
                devices: { () async throws(AccountError) -> [AccountDevice] in try await services.fetchDevices() }
            )
        }
    }

    static let freshness: TimeInterval = 60

    @Published private(set) var profile = AccountRemote<AccountProfile>()
    @Published private(set) var devices = AccountRemote<[AccountDevice]>()
    @Published private(set) var activity: Activity?
    @Published private(set) var signInFailure: String?
    @Published var actionFailure: AccountActionFailure?
    @Published var presentsDeviceLimit = false
    @Published var presentsLicenseKey = false
    // Read once when the sheet opens, not on every render: it comes from the Keychain.
    @Published private(set) var licenseKeyPrefill: String?
    @Published var presentsOfflineImporter = false
    @Published var pendingRemoval: AccountSettingsContent.DeviceRow?

    let services: AccountServices
    private let loader: Loader
    private let now: () -> Date
    private let openURL: @MainActor (URL) -> Void
    private let teamLibrary: @MainActor () -> TeamLibrary
    private let askSignOut: @MainActor (AccountSignOutConfirmation) async -> AccountSignOutAnswer
    private let closeSignOutQuestion: @MainActor () -> Void
    private var asksSignOut = false
    private var stateObserver: AnyCancellable?
    private var loadedSignedIn: Bool?
    // Bumped when the loaded data is dropped, so a load still out for the old account lands nowhere.
    private var generation = 0
    private var lastLoad: Date?
    private var returnsFromPortal = false

    init(
        services: AccountServices,
        loader: Loader? = nil,
        now: @escaping () -> Date = { Date() },
        openURL: @escaping @MainActor (URL) -> Void = { _ = WebPageOpener.open($0, scope: .httpsOrLoopbackHTTP) },
        teamLibrary: @escaping @MainActor () -> TeamLibrary = { .shared },
        askSignOut: @escaping @MainActor (AccountSignOutConfirmation) async -> AccountSignOutAnswer = AccountSignOutPrompt.ask,
        closeSignOutQuestion: @escaping @MainActor () -> Void = AccountSignOutPrompt.close
    ) {
        self.services = services
        self.loader = loader ?? .live(services)
        self.now = now
        self.openURL = openURL
        self.teamLibrary = teamLibrary
        self.askSignOut = askSignOut
        self.closeSignOutQuestion = closeSignOutQuestion
        stateObserver = services.access.$state
            .dropFirst()
            .sink { [weak self] state in
                guard let self else { return }
                objectWillChange.send()
                // Signed out some other way while Sign Out asks: nothing is left to sign out of.
                if !state.isSignedIn, asksSignOut {
                    closeSignOutQuestion()
                }
                if let loadedSignedIn, state.isSignedIn != loadedSignedIn {
                    Task { await self.reload() }
                }
            }
    }

    var access: FeatureAccess {
        services.access
    }

    var content: AccountSettingsContent {
        AccountSettingsContent.make(
            state: services.access.state,
            profile: profile.value,
            devices: devices.value,
            machineID: services.machineID,
            now: now()
        )
    }

    var isBusy: Bool {
        activity != nil
    }

    // Every show of the pane and every return to the window: a portal visit may have changed the account.
    func refreshOnVisit() async {
        guard returnsFromPortal else {
            await reloadIfStale()
            return
        }
        returnsFromPortal = false
        await services.checkNow()
        await reload()
    }

    func reloadIfStale() async {
        if services.access.state.isSignedIn == loadedSignedIn, let lastLoad,
           now().timeIntervalSince(lastLoad) < Self.freshness {
            return
        }
        await reload()
    }

    // Keeps what it loaded before when a load fails; a sign-in or sign-out drops it first.
    func reload() async {
        let isSignedIn = services.access.state.isSignedIn
        if isSignedIn != loadedSignedIn {
            forgetLoaded()
            loadedSignedIn = isSignedIn
        }
        guard isSignedIn else { return }
        let started = generation
        async let profileLoad = loadProfile()
        async let devicesLoad = loadDevices()
        let (profileLoaded, devicesLoaded) = await (profileLoad, devicesLoad)
        guard started == generation, profileLoaded, devicesLoaded else { return }
        lastLoad = now()
    }

    @discardableResult
    func loadProfile() async -> Bool {
        let started = generation
        profile.isLoading = true
        do throws(AccountError) {
            let value = try await loader.profile()
            guard started == generation else { return false }
            profile = AccountRemote(value: value)
            return true
        } catch .canceled {
            if started == generation {
                profile.isLoading = false
            }
            return false
        } catch {
            guard started == generation else { return false }
            profile.isLoading = false
            profile.failure = error.friendlyDescription ?? String(localized: "Could not load your teams.")
            return false
        }
    }

    @discardableResult
    func loadDevices() async -> Bool {
        let started = generation
        devices.isLoading = true
        do throws(AccountError) {
            let value = try await loader.devices()
            guard started == generation else { return false }
            devices = AccountRemote(value: value)
            return true
        } catch .canceled {
            if started == generation {
                devices.isLoading = false
            }
            return false
        } catch {
            guard started == generation else { return false }
            devices.isLoading = false
            devices.failure = error.friendlyDescription ?? String(localized: "Could not load your devices.")
            return false
        }
    }

    func signIn(using authenticator: some WebAuthenticating) async {
        signInFailure = nil
        activity = .signingIn
        defer { activity = nil }
        do throws(AccountError) {
            try await services.signIn(using: authenticator)
        } catch {
            signInFailure = error.friendlyDescription
            return
        }
        presentDeviceLimitIfReached()
    }

    // The whole of Sign Out. What an upload leaves is asked about again; signed out another way meanwhile, the flow
    // ends and the data stays with its owner. Once signed out, the account's Team Library data is deleted, verified.
    func signOut() async {
        guard activity == nil else { return }
        activity = .signingOut
        defer { activity = nil }
        let teamLibrary = teamLibrary()
        var changes = await teamLibrary.unsentChanges()
        var failure: TeamLibraryFailure?
        while services.isSignedIn {
            asksSignOut = true
            let answer = await askSignOut(AccountSignOutConfirmation(
                teamChanges: changes,
                uploadFailure: failure,
                removesOfflineFile: services.access.state.entitlement?.isOffline == true
            ))
            asksSignOut = false
            guard services.isSignedIn else { return }
            switch answer {
            case .cancel:
                return
            case .discard:
                await finishSignOut(teamLibrary)
                return
            case .upload:
                (changes, failure) = await teamLibrary.upload()
                if changes.isEmpty, services.isSignedIn {
                    await finishSignOut(teamLibrary)
                    return
                }
            }
        }
    }

    private func finishSignOut(_ teamLibrary: TeamLibrary) async {
        let deleted = await teamLibrary.signOut { [services] in await services.signOut() }
        guard !deleted else { return }
        actionFailure = AccountActionFailure(
            title: String(localized: "Team Library data is still on this Mac"),
            message: String(localized: "TablePro couldn't delete the Team Library data of the account you signed out of. Team Library stays off until it can.")
        )
    }

    func checkNow() async {
        activity = .checking
        defer { activity = nil }
        await services.checkNow()
        await reload()
    }

    // The next return to the window checks the account again: billing, devices and teams change in the portal.
    func openPortal(_ url: URL) {
        returnsFromPortal = true
        openURL(url)
    }

    func removeDevice(_ device: AccountSettingsContent.DeviceRow) async {
        pendingRemoval = nil
        activity = .removing(device.id)
        defer { activity = nil }
        do throws(AccountError) {
            try await services.removeDevice(device.id)
        } catch {
            actionFailure = error.deviceRemovalDescription.map {
                AccountActionFailure(
                    title: String(format: String(localized: "Could not remove “%@”"), device.name),
                    message: $0
                )
            }
        }
        await loadDevices()
    }

    func importOfflineFile(at url: URL) async {
        activity = .importing
        defer { activity = nil }
        do throws(AccountError) {
            try await services.importOfflineFile(at: url)
        } catch {
            actionFailure = error.offlineFileDescription.map {
                AccountActionFailure(title: String(localized: "Could not import the offline file"), message: $0)
            }
        }
    }

    func offlineFilePickerFailed(_ error: any Error) {
        actionFailure = AccountActionFailure(
            title: String(localized: "Could not import the offline file"),
            message: error.localizedDescription
        )
    }

    // Nil when the key signed this Mac in or the exchange was canceled; the message to show beside the key otherwise.
    func useLicenseKey(_ key: String) async -> String? {
        activity = .usingKey
        defer { activity = nil }
        do throws(AccountError) {
            _ = try await services.useLicenseKey(key)
        } catch .canceled {
            return nil
        } catch {
            return error.licenseKeyDescription ?? String(localized: "Could not use this license key.")
        }
        presentsLicenseKey = false
        presentDeviceLimitIfReached()
        // The key may belong to another account than the one signed in before. The sheet closing cancels its own
        // task, so the reload runs outside it.
        forgetLoaded()
        Task { await reload() }
        return nil
    }

    func presentLicenseKey() {
        licenseKeyPrefill = services.storedLicenseKey
        presentsLicenseKey = true
    }

    func presentDeviceLimitIfReached() {
        if case .deviceLimitReached = services.access.state.refresh {
            presentsDeviceLimit = true
        }
    }

    private func forgetLoaded() {
        generation += 1
        lastLoad = nil
        profile = AccountRemote()
        devices = AccountRemote()
    }
}
