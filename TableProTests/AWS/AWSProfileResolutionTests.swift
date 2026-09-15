import Foundation
import TableProPluginKit
import Testing

@Suite("AWS profile credential source")
struct AWSProfileResolutionTests {
    @Test("A profile resolves by what it declares, in the AWS SDK's order")
    func credentialSourceOrder() {
        #expect(
            AWSCredentialResolver.credentialSource(for: [
                "web_identity_token_file": "/tmp/token",
                "role_arn": "arn:aws:iam::111:role/Web"
            ]) == .webIdentity
        )
        #expect(
            AWSCredentialResolver.credentialSource(for: [
                "role_arn": "arn:aws:iam::222:role/Admin",
                "source_profile": "corp",
                "sso_session": "corp"
            ]) == .assumeRole(roleArn: "arn:aws:iam::222:role/Admin")
        )
        #expect(
            AWSCredentialResolver.credentialSource(for: [
                "sso_session": "corp",
                "sso_account_id": "111122223333",
                "sso_role_name": "ReadOnly"
            ]) == .singleSignOn
        )
        #expect(
            AWSCredentialResolver.credentialSource(for: ["sso_start_url": "https://example.awsapps.com/start"])
                == .singleSignOn
        )
        #expect(
            AWSCredentialResolver.credentialSource(for: [
                "aws_access_key_id": "AKIA",
                "aws_secret_access_key": "secret",
                "credential_process": "/usr/local/bin/helper"
            ]) == .staticKeys
        )
        #expect(
            AWSCredentialResolver.credentialSource(for: ["credential_process": "/usr/local/bin/helper"])
                == .credentialProcess(command: "/usr/local/bin/helper")
        )
        #expect(AWSCredentialResolver.credentialSource(for: ["region": "us-east-1"]) == .undeclared)
        #expect(AWSCredentialResolver.credentialSource(for: [:]) == .undeclared)
    }

    @Test("Each source reports the kind the sheet shows")
    func kinds() {
        #expect(AWSProfileCredentialSource.singleSignOn.kind == .singleSignOn)
        #expect(AWSProfileCredentialSource.assumeRole(roleArn: "arn").kind == .assumeRole)
        #expect(AWSProfileCredentialSource.staticKeys.kind == .accessKey)
        #expect(AWSProfileCredentialSource.credentialProcess(command: "x").kind == .credentialProcess)
        #expect(AWSProfileCredentialSource.webIdentity.kind == .webIdentity)
        #expect(AWSProfileCredentialSource.undeclared.kind == .unknown)
    }

    @Test("An SSO profile is recognised through an sso-session and through the inline keys")
    func ssoProfilesFromConfigFile() {
        let config = """
        [sso-session corp]
        sso_start_url = https://example.awsapps.com/start
        sso_region = us-east-1

        [profile corp]
        sso_session = corp
        sso_account_id = 111122223333
        sso_role_name = ReadOnly
        region = eu-west-1

        [profile legacy]
        sso_start_url = https://example.awsapps.com/start
        sso_region = us-east-1
        sso_account_id = 111122223333
        sso_role_name = ReadOnly

        [profile prod]
        role_arn = arn:aws:iam::222:role/Admin
        source_profile = corp
        """

        func source(_ profile: String) -> AWSProfileCredentialSource {
            AWSCredentialResolver.credentialSource(
                for: AWSConfigFile.mergedProfileSettings(
                    profileName: profile,
                    configContents: config,
                    credentialsContents: nil
                )
            )
        }

        #expect(source("corp") == .singleSignOn)
        #expect(source("legacy") == .singleSignOn)
        #expect(source("prod") == .assumeRole(roleArn: "arn:aws:iam::222:role/Admin"))
    }

    @Test("The assume-role signing region prefers the profile's own region")
    func signingRegion() {
        #expect(AWSCredentialResolver.signingRegion(for: ["region": "eu-west-1"]) == "eu-west-1")
        #expect(AWSCredentialResolver.signingRegion(for: ["region": "EU-West-1 "]) == "eu-west-1")
        #expect(AWSCredentialResolver.signingRegion(for: ["region": ""]) == "us-east-1")
        #expect(AWSCredentialResolver.signingRegion(for: [:]) == "us-east-1")
    }

    @Test("A profile with no region signs STS in the role's own partition")
    func signingRegionFromRoleARN() {
        #expect(
            AWSCredentialResolver.signingRegion(for: [:], roleArn: "arn:aws-cn:iam::111:role/Admin")
                == "cn-north-1"
        )
        #expect(
            AWSCredentialResolver.signingRegion(for: [:], roleArn: "arn:aws-us-gov:iam::111:role/Admin")
                == "us-gov-west-1"
        )
        #expect(
            AWSCredentialResolver.signingRegion(for: [:], roleArn: "arn:aws-iso:iam::111:role/Admin")
                == "us-iso-east-1"
        )
        #expect(
            AWSCredentialResolver.signingRegion(
                for: ["region": "cn-northwest-1"],
                roleArn: "arn:aws-cn:iam::111:role/Admin"
            ) == "cn-northwest-1"
        )
    }
}
