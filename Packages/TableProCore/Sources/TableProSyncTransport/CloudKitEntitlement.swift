import Foundation
#if targetEnvironment(simulator)
import MachO
#endif
#if os(macOS)
import Security
#endif

enum CloudKitEntitlement {
    static let servicesKey = "com.apple.developer.icloud-services"
    private static let grantingServices: Set<String> = ["CloudKit", "CloudKit-Anonymous"]

    static func grants(servicesValue value: Any?) -> Bool {
        guard let services = value as? [String] else { return false }
        return !grantingServices.isDisjoint(with: services)
    }

    static func grants(entitlementsPropertyList data: Data) -> Bool {
        let plist = try? PropertyListSerialization.propertyList(from: data, format: nil)
        guard let entitlements = plist as? [String: Any] else { return false }
        return grants(servicesValue: entitlements[servicesKey])
    }

    static func isGrantedToCurrentProcess() -> Bool {
        #if os(macOS)
        guard let task = SecTaskCreateFromSelf(nil) else { return false }
        return grants(servicesValue: SecTaskCopyValueForEntitlement(task, servicesKey as CFString, nil))
        #elseif targetEnvironment(simulator)
        guard let data = mainExecutableSection(segment: "__TEXT", section: "__entitlements") else { return false }
        return grants(entitlementsPropertyList: data)
        #else
        return true
        #endif
    }

    #if targetEnvironment(simulator)
    private static func mainExecutableSection(segment: String, section: String) -> Data? {
        for index in 0..<_dyld_image_count() {
            guard let header = _dyld_get_image_header(index), header.pointee.filetype == UInt32(MH_EXECUTE) else {
                continue
            }
            var size: UInt = 0
            let bytes = header.withMemoryRebound(to: mach_header_64.self, capacity: 1) {
                getsectiondata($0, segment, section, &size)
            }
            guard let bytes, size > 0 else { return nil }
            return Data(bytes: bytes, count: Int(size))
        }
        return nil
    }
    #endif
}
