import Foundation
import Testing

@testable import TableProSyncTransport

@Suite("CloudKit entitlement")
struct CloudKitEntitlementTests {
    private func propertyList(_ entitlements: [String: Any]) throws -> Data {
        try PropertyListSerialization.data(fromPropertyList: entitlements, format: .xml, options: 0)
    }

    @Test("CloudKit and CloudKit-Anonymous each grant the container", arguments: ["CloudKit", "CloudKit-Anonymous"])
    func grantingService(_ service: String) {
        #expect(CloudKitEntitlement.grants(servicesValue: [service]))
        #expect(CloudKitEntitlement.grants(servicesValue: ["CloudDocuments", service]))
    }

    @Test("iCloud Documents alone does not grant CloudKit")
    func documentsAlone() {
        #expect(!CloudKitEntitlement.grants(servicesValue: ["CloudDocuments"]))
    }

    @Test("A missing, empty or mistyped value grants nothing")
    func missingOrMalformed() {
        #expect(!CloudKitEntitlement.grants(servicesValue: nil))
        #expect(!CloudKitEntitlement.grants(servicesValue: [String]()))
        #expect(!CloudKitEntitlement.grants(servicesValue: "CloudKit"))
        #expect(!CloudKitEntitlement.grants(servicesValue: ["CloudKit": true]))
    }

    @Test("The entitlements a signed simulator build embeds grant CloudKit")
    func signedSimulatorEntitlements() throws {
        let data = try propertyList([
            "application-identifier": "TEAMID.com.TablePro.TableProMobile",
            "com.apple.developer.icloud-container-identifiers": ["iCloud.com.TablePro"],
            CloudKitEntitlement.servicesKey: ["CloudKit"]
        ])
        #expect(CloudKitEntitlement.grants(entitlementsPropertyList: data))
    }

    @Test("Entitlements without iCloud services grant nothing")
    func entitlementsWithoutICloud() throws {
        let data = try propertyList(["keychain-access-groups": ["TEAMID.com.TablePro.shared"]])
        #expect(!CloudKitEntitlement.grants(entitlementsPropertyList: data))
    }

    @Test("An empty or unreadable section grants nothing")
    func unreadableSection() {
        #expect(!CloudKitEntitlement.grants(entitlementsPropertyList: Data()))
        #expect(!CloudKitEntitlement.grants(entitlementsPropertyList: Data("not a plist".utf8)))
    }
}
