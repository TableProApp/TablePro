import Foundation
@testable import TableProMobile

@MainActor
final class StubDeviceOwnerAuthenticator: DeviceOwnerAuthenticating {
    let availability: BiometricAuthService.Availability
    private let answer: Bool
    private(set) var requests = 0

    init(availability: BiometricAuthService.Availability = .faceID, answer: Bool) {
        self.availability = availability
        self.answer = answer
    }

    func authenticate(reason: String) async -> Bool {
        requests += 1
        return answer
    }
}
