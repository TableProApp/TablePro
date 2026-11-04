import TableProConnectionLibrary
import Testing

struct ConnectionSecretOptionsTests {
    @Test("Credential options of a MongoDB connection string are secret in any case", arguments: [
        "mongoParam_tlsCertificateKeyFilePassword",
        "mongoparam_TLSCERTIFICATEKEYFILEPASSWORD",
        "mongoParam_sslClientCertificateKeyPassword",
        "mongoParam_proxyPassword",
        "mongoAWSSessionToken"
    ])
    func credentialOptionsAreSecret(key: String) {
        #expect(ConnectionSecretOptions.isSecret(key: key, value: "hunter2"))
    }

    @Test("Ordinary options and other fields are not secret", arguments: [
        "mongoParam_proxyHost",
        "mongoParam_retryWrites",
        "mongoParam_",
        "tlsCertificateKeyFilePassword",
        "mongoAuthSource"
    ])
    func ordinaryOptionsAreNotSecret(key: String) {
        #expect(!ConnectionSecretOptions.isSecret(key: key, value: "x"))
    }

    @Test("Mechanism properties are secret only while they carry a session token")
    func mechanismPropertiesCarryingAToken() {
        let key = "mongoParam_authMechanismProperties"
        #expect(ConnectionSecretOptions.isSecret(key: key, value: "AWS_SESSION_TOKEN:FQoG"))
        #expect(ConnectionSecretOptions.isSecret(key: key, value: "SERVICE_NAME:mongodb, aws_session_token:FQoG"))
        #expect(!ConnectionSecretOptions.isSecret(key: key, value: "SERVICE_NAME:mongodb"))
        #expect(!ConnectionSecretOptions.isSecret(key: key, value: "AWS_SESSION_TOKEN:"))
    }

    @Test("The session token splits out of the properties and joins back")
    func splitAndJoin() {
        let split = ConnectionSecretOptions.splitSessionToken(from: "SERVICE_NAME:mongodb,AWS_SESSION_TOKEN:ab/c+d=")
        #expect(split.remaining == "SERVICE_NAME:mongodb")
        #expect(split.sessionToken == "ab/c+d=")
        #expect(ConnectionSecretOptions.splitSessionToken(from: "AWS_SESSION_TOKEN:t").remaining == nil)
        #expect(ConnectionSecretOptions.joiningSessionToken("t", to: nil) == "AWS_SESSION_TOKEN:t")
        #expect(
            ConnectionSecretOptions.joiningSessionToken("t", to: "SERVICE_NAME:mongodb,AWS_SESSION_TOKEN:old")
                == "SERVICE_NAME:mongodb,AWS_SESSION_TOKEN:t"
        )
    }

    @Test("Removing secrets keeps every other field and the properties beside the token")
    func removingSecrets() {
        let fields = [
            "mongoParam_tlsCertificateKeyFilePassword": "hunter2",
            "mongoParam_proxyPassword": "proxy-secret",
            "mongoParam_authMechanismProperties": "SERVICE_NAME:mongodb,AWS_SESSION_TOKEN:FQoG",
            "mongoParam_retryWrites": "true",
            "mongoAuthSource": "admin"
        ]

        #expect(ConnectionSecretOptions.removingSecrets(from: fields) == [
            "mongoParam_authMechanismProperties": "SERVICE_NAME:mongodb",
            "mongoParam_retryWrites": "true",
            "mongoAuthSource": "admin"
        ])
    }
}
