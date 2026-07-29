import Foundation
import TableProPluginKit
import Testing

@Suite("AWS config and credentials file resolution")
struct AWSConfigFileTests {
    private let config = """
    [default]
    region = us-east-1
    aws_access_key_id = CONFIG_DEFAULT_KEY
    aws_secret_access_key = CONFIG_DEFAULT_SECRET

    [profile c9dev]
    region = ap-south-1
    credential_process = /opt/bin/awscreds --profile c9dev

    [profile static-in-config]
    aws_access_key_id = CONFIG_KEY
    aws_secret_access_key = CONFIG_SECRET

    [sso-session my-sso]
    sso_start_url = https://example.awsapps.com/start
    sso_region = us-east-1
    """

    private let credentials = """
    [work]
    aws_access_key_id = CREDS_WORK_KEY
    aws_secret_access_key = CREDS_WORK_SECRET

    [static-in-config]
    aws_access_key_id = CREDS_OVERRIDE_KEY
    aws_secret_access_key = CREDS_OVERRIDE_SECRET
    """

    @Test("A profile defined only in ~/.aws/config resolves (the reported bug)")
    func profileOnlyInConfig() {
        let settings = AWSConfigFile.mergedProfileSettings(
            profileName: "c9dev",
            configContents: config,
            credentialsContents: credentials
        )
        #expect(settings["credential_process"] == "/opt/bin/awscreds --profile c9dev")
        #expect(settings["region"] == "ap-south-1")
    }

    @Test("A profile defined only in ~/.aws/credentials resolves")
    func profileOnlyInCredentials() {
        let settings = AWSConfigFile.mergedProfileSettings(
            profileName: "work",
            configContents: config,
            credentialsContents: credentials
        )
        #expect(settings["aws_access_key_id"] == "CREDS_WORK_KEY")
        #expect(settings["aws_secret_access_key"] == "CREDS_WORK_SECRET")
    }

    @Test("When a profile is in both files, the credentials file wins")
    func credentialsFileWins() {
        let settings = AWSConfigFile.mergedProfileSettings(
            profileName: "static-in-config",
            configContents: config,
            credentialsContents: credentials
        )
        #expect(settings["aws_access_key_id"] == "CREDS_OVERRIDE_KEY")
    }

    @Test("The default profile uses [default] in config and [default] in credentials")
    func defaultProfile() {
        let settings = AWSConfigFile.mergedProfileSettings(
            profileName: "default",
            configContents: config,
            credentialsContents: credentials
        )
        #expect(settings["aws_access_key_id"] == "CONFIG_DEFAULT_KEY")
        #expect(settings["region"] == "us-east-1")
    }

    @Test("A missing profile yields no settings")
    func missingProfile() {
        let settings = AWSConfigFile.mergedProfileSettings(
            profileName: "nope",
            configContents: config,
            credentialsContents: credentials
        )
        #expect(settings.isEmpty)
    }

    @Test("Profile discovery merges both files, drops sso-session, and lists default first")
    func discovery() {
        let profiles = AWSConfigFile.discoverProfiles(
            configContents: config,
            credentialsContents: credentials
        )
        #expect(profiles == ["default", "c9dev", "static-in-config", "work"])
    }

    @Test("Discovery deduplicates a profile present in both files")
    func discoveryDedupes() {
        let profiles = AWSConfigFile.discoverProfiles(
            configContents: config,
            credentialsContents: credentials
        )
        #expect(profiles.filter { $0 == "static-in-config" }.count == 1)
    }
}
