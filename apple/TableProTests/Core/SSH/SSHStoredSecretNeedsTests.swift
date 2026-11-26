//
//  SSHStoredSecretNeedsTests.swift
//  TableProTests
//

import Foundation
@testable import TablePro
import TableProSSHConfig
import TableProSSHTransport
import Testing

struct SSHStoredSecretNeedsTests {
    @Test("Each sign-in method reads only the secrets it can use")
    func eachMethodReadsItsOwnSecrets() {
        #expect(reads(.password) == [true, false, false])
        #expect(reads(.keyboardInteractive) == [true, false, false])
        #expect(reads(.privateKey) == [false, true, false])
        #expect(reads(.sshAgent) == [false, false, false])
        #expect(reads(.none) == [false, false, false])
    }

    private func reads(_ method: SSHAuthMethod) -> [Bool] {
        let needs = SSHStoredSecretNeeds(authMethod: method, totpMode: .none, passwordGiven: false)
        return [needs.password, needs.keyPassphrase, needs.totpSecret]
    }

    @Test("A generated code reads the TOTP secret, a prompted one does not")
    func totpSecretOnlyWhenGenerated() {
        #expect(SSHStoredSecretNeeds(authMethod: .sshAgent, totpMode: .autoGenerate, passwordGiven: false).totpSecret)
        #expect(!SSHStoredSecretNeeds(authMethod: .sshAgent, totpMode: .promptAtConnect, passwordGiven: false).totpSecret)
    }

    @Test("A password typed for Test Connection leaves the stored one unread")
    func typedPasswordSkipsStoredOne() {
        #expect(!SSHStoredSecretNeeds(authMethod: .password, totpMode: .none, passwordGiven: true).password)
    }
}
