//
//  PreferenceKeysGuardTests.swift
//  TableProTests
//

@testable import TablePro
import Testing

struct PreferenceKeysGuardTests {
    @Test("Registered keys are unique and namespaced")
    func registryIsCleanlyNamespaced() {
        let names = PreferenceKeys.registeredKeyNames
        #expect(Set(names).count == names.count)
        for name in names {
            #expect(name.hasPrefix("com.TablePro."), "Key '\(name)' is outside the com.TablePro namespace")
        }
    }

    @Test("The inspector's field preferences are registered under their own names")
    func inspectorFieldKeysAreRegistered() {
        let keys = [
            PreferenceKeys.rowInspectorJsonFieldHeight.name,
            PreferenceKeys.rowInspectorTextFieldHeight.name,
            PreferenceKeys.rowInspectorGeometryFieldHeight.name,
            PreferenceKeys.rowInspectorGeometryFieldMode.name,
        ]
        #expect(Set(keys).count == keys.count)
        for key in keys {
            #expect(PreferenceKeys.registeredKeyNames.contains(key), "\(key) is not registered")
        }
    }
}
