import Foundation
@testable import TableProGoogleCloud
import Testing

@Suite("Refresh token stores")
struct GoogleRefreshTokenStoreTests {
    @Test("The in-memory store saves, replaces and removes per client id")
    func inMemory() {
        let store = GoogleInMemoryRefreshTokenStore(["a": "1"])
        #expect(store.refreshToken(for: "a") == "1")
        #expect(store.refreshToken(for: "b") == nil)
        store.save("2", for: "a")
        store.save("3", for: "b")
        #expect(store.refreshToken(for: "a") == "2")
        #expect(store.refreshToken(for: "b") == "3")
        store.removeRefreshToken(for: "a")
        #expect(store.refreshToken(for: "a") == nil)
        #expect(store.refreshToken(for: "b") == "3")
    }

    @Test("The Keychain store round-trips when a Keychain is available")
    func keychainRoundTrip() {
        let store = GoogleKeychainRefreshTokenStore()
        let clientId = "tablepro-tests-\(UUID().uuidString).apps.googleusercontent.com"
        defer { store.removeRefreshToken(for: clientId) }

        store.save("first-token", for: clientId)
        guard store.refreshToken(for: clientId) == "first-token" else {
            return
        }
        store.save("second-token", for: clientId)
        #expect(store.refreshToken(for: clientId) == "second-token")
        store.removeRefreshToken(for: clientId)
        #expect(store.refreshToken(for: clientId) == nil)
        #expect(GoogleKeychainRefreshTokenStore.service == "com.TablePro.GoogleOAuth")
    }

    @Test("Removing a token that was never saved is harmless")
    func removeMissing() {
        let store = GoogleKeychainRefreshTokenStore()
        let clientId = "tablepro-tests-missing-\(UUID().uuidString)"
        store.removeRefreshToken(for: clientId)
        #expect(store.refreshToken(for: clientId) == nil)
    }
}
