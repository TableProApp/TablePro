namespace TablePro.Core.Tests.Updates;

/// <summary>Feeds in the shape <c>windows/packaging/Update-Feed.ps1</c> writes.</summary>
internal static class FeedFixtures
{
    public const string ZipX64Sha = "1111111111111111111111111111111111111111111111111111111111111111";
    public const string MsixArm64Sha = "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA";

    public const string Sample = """
        {
          "schema": 1,
          "items": [
            {
              "version": "0.2.0-beta.1",
              "channel": "beta",
              "published": "2026-11-02T08:00:00Z",
              "releaseNotesUrl": "https://github.com/TableProApp/TablePro/releases/tag/windows-v0.2.0-beta.1",
              "notes": "Beta notes",
              "minimumWindowsBuild": 19041,
              "assets": [
                { "kind": "zip", "architecture": "x64", "url": "https://github.com/TableProApp/TablePro/releases/download/windows-v0.2.0-beta.1/TablePro-0.2.0-beta.1-x64.zip", "size": 100, "sha256": "2222222222222222222222222222222222222222222222222222222222222222" }
              ]
            },
            {
              "version": "0.1.1",
              "channel": "stable",
              "published": "2026-10-30T08:00:00Z",
              "phasedRolloutInterval": 21600,
              "critical": false,
              "minimumWindowsBuild": 19041,
              "notes": "Stable notes",
              "futureField": { "ignored": true },
              "assets": [
                { "kind": "zip", "architecture": "x64", "url": "https://example.test/TablePro-0.1.1-x64.zip", "size": 1234, "sha256": "1111111111111111111111111111111111111111111111111111111111111111" },
                { "kind": "msix", "architecture": "arm64", "url": "https://example.test/TablePro-0.1.1-arm64.msix", "size": 4321, "sha256": "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA" },
                { "kind": "msixbundle", "architecture": "x64", "url": "https://example.test/a.msixbundle", "size": 1, "sha256": "1111111111111111111111111111111111111111111111111111111111111111" },
                { "kind": "zip", "architecture": "x86", "url": "https://example.test/x86.zip", "size": 1, "sha256": "1111111111111111111111111111111111111111111111111111111111111111" },
                { "kind": "zip", "architecture": "arm64", "url": "http://example.test/plain-http.zip", "size": 1, "sha256": "1111111111111111111111111111111111111111111111111111111111111111" },
                { "kind": "msix", "architecture": "x64", "url": "https://example.test/short-digest.msix", "size": 1, "sha256": "abc" }
              ]
            },
            { "version": "0.1.0-rc.1", "published": "2026-10-01T00:00:00Z", "assets": [] },
            { "version": "0.1.0", "assets": [] },
            null
          ]
        }
        """;
}
