using System.Text.RegularExpressions;
using TablePro.Interop;

namespace TablePro.App.Model.Tests;

// The names SyncText builds from a state, and every code the core's sync, keys and account can answer with.
public sealed partial class LocalizationTests
{
    // Where the core's sync, keys and account errors name their codes. CloudKit's are iCloud's, which Windows never
    // runs, so they are left out.
    private static readonly string[] CodeSources =
    [
        "sync/src/api/error.rs",
        "sync/src/api/transport.rs",
        "sync/src/api/device_store.rs",
        "sync/src/api/team_library.rs",
        "keys/src/error.rs",
        "account/src/account_error.rs",
        "account/src/server.rs",
        "account/src/license.rs",
        "ffi/src/account/account_service.rs",
    ];

    [Fact]
    public void EverySyncStateTheSectionShowsHasItsWords()
    {
        var names = Enum.GetValues<SyncStatusKind>().Select(kind => "SyncStatus" + kind)
            .Concat(Enum.GetValues<SyncLockCause>().SelectMany(cause =>
                new[] { "SyncLockTitle_" + cause, "SyncLockMessage_" + cause }))
            .Concat(Enum.GetValues<SyncServerPolicy>().Select(policy => "SyncPolicy_" + policy))
            .Concat(Enum.GetValues<SyncRefusal>().Select(refusal => "SyncRefusal_" + refusal))
            .Concat(Enum.GetValues<UploadKeysStep>().Select(step => "SyncUploadKeys_" + step))
            .Concat(["SyncProviderOffSummary", "SyncProviderTableProSyncSummary", "SyncPasswordsEncrypted"])
            .Concat(["SyncPasswordsOffOnServer", "SyncUploadButton", "AccountTryAgain"]);

        Assert.Empty(names.Where(name => !s_strings.Value.ContainsKey(name)));
    }

    [Fact]
    public void EveryCodeTheCoresSyncKeysAndAccountReturnIsWorded()
    {
        var crates = Path.Combine(Sources, "..", "..", "core", "crates");
        var codes = CodeSources
            .SelectMany(file => CoreCode().Matches(File.ReadAllText(Path.Combine(crates, file))))
            .Select(match => match.Groups["code"].Value)
            .Distinct(StringComparer.Ordinal)
            .ToList();

        Assert.Contains("sync.network", codes);
        Assert.Contains("keys.recovery_key", codes);
        Assert.Contains("account.step_up_required", codes);
        Assert.Empty(codes.Where(code => !s_strings.Value.ContainsKey("Error_" + code.Replace('.', '_'))));
    }

    // A code as a match arm, a worded refusal's pair or a failure the FFI builds names it; a bare string is a detail.
    [GeneratedRegex(@"(?:=>\s*|,\s*|failed\()""(?<code>(?:sync|keys|account)\.[a-z_]+(?:\.[a-z_]+)?)""")]
    private static partial Regex CoreCode();
}
