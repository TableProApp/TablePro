import Foundation
@testable import TablePro
import Testing

struct NotificationSettingsTests {
    @Test("A threshold on the list offers exactly the fixed choices")
    func onListValueKeepsTheChoices() {
        for seconds in NotificationSettings.thresholdChoices {
            let settings = NotificationSettings(thresholdSeconds: seconds)
            #expect(settings.thresholdOptions == NotificationSettings.thresholdChoices)
        }
    }

    @Test("A threshold off the list is offered in order among the choices", arguments: [
        (45, [5, 10, 20, 30, 45, 60, 120, 300, 600]),
        (90, [5, 10, 20, 30, 60, 90, 120, 300, 600]),
    ])
    func offListValueIsInserted(seconds: Int, expected: [Int]) {
        let settings = NotificationSettings(thresholdSeconds: seconds)
        #expect(settings.thresholdOptions == expected)
    }

    @Test("A threshold outside the allowed range offers the value that applies")
    func outOfRangeValueOffersTheClamp() {
        #expect(NotificationSettings(thresholdSeconds: 1).thresholdOptions == NotificationSettings.thresholdChoices)
        #expect(NotificationSettings(thresholdSeconds: 900).thresholdOptions == NotificationSettings.thresholdChoices)
        #expect(NotificationSettings(thresholdSeconds: 7).thresholdOptions == [5, 7, 10, 20, 30, 60, 120, 300, 600])
    }

    @Test("The default threshold is one of the choices")
    func defaultIsOnTheList() {
        #expect(NotificationSettings.thresholdChoices.contains(NotificationSettings.default.thresholdSeconds))
    }

    @Test("A stored record with the legacy kind list still decodes its fields")
    func ignoresLegacyKindIds() throws {
        let json = #"{"isEnabled":false,"thresholdSeconds":90,"disabledKindIds":["export"]}"#
        let settings = try JSONDecoder().decode(NotificationSettings.self, from: Data(json.utf8))
        #expect(settings == NotificationSettings(isEnabled: false, thresholdSeconds: 90))
    }
}
