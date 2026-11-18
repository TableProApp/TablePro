using System.Runtime.InteropServices;
using TablePro.Interop;
using Windows.System;

namespace TablePro.App.Services;

// The TablePro account's settings (docs/decisions/0008-tablepro-account.md); a release build always uses tablepro.app.
internal static class AccountSetup
{
    public static readonly Uri ProductionPortal = new("https://account.tablepro.app");
    public static readonly Uri PricingUri = new("https://tablepro.app/#pricing");

    public static AccountConfiguration Configuration(string folder)
    {
        var configuration = new AccountConfiguration(
            Environment.MachineName,
            AppStorage.Version,
            RuntimeInformation.OSDescription,
            Path.Combine(folder, "account.json"),
            Strings.Get("AccountCallbackFinished"),
            Strings.Get("AccountCallbackUnknown"));
#if DEBUG
        // A development build may sign in to a local tablepro-cloud; both URLs go together, as the core requires.
        if (Development() is { } stack)
        {
            return configuration with
            {
                AccountUrl = stack.Account,
                ApiUrl = stack.Api,
                EntitlementKeys = stack.Keys,
            };
        }
#endif
        return configuration;
    }

    public static Uri Portal()
    {
#if DEBUG
        if (Development() is { } stack && Uri.TryCreate(stack.Account, UriKind.Absolute, out var local))
        {
            return local;
        }
#endif
        return ProductionPortal;
    }

    public static Uri SharedLinksPage(Uri portal) => new(portal, "shared-links");

#if DEBUG
    private static (string Account, string Api, string[] Keys)? Development()
    {
        var account = Environment.GetEnvironmentVariable("TABLEPRO_ACCOUNT_URL");
        var api = Environment.GetEnvironmentVariable("TABLEPRO_API_URL");
        if (string.IsNullOrWhiteSpace(account) || string.IsNullOrWhiteSpace(api))
        {
            return null;
        }

        var keys = (Environment.GetEnvironmentVariable("TABLEPRO_ENTITLEMENT_KEYS") ?? string.Empty)
            .Split(',', StringSplitOptions.RemoveEmptyEntries | StringSplitOptions.TrimEntries);
        return (account.Trim(), api.Trim(), keys);
    }
#endif
}

// The core asks on a thread of its own; Launcher runs on the UI thread, where the window it opens over lives.
internal sealed class SystemBrowser(Microsoft.UI.Dispatching.DispatcherQueue queue) : IAccountBrowser
{
    public Task<bool> OpenAsync(Uri url)
    {
        var opened = new TaskCompletionSource<bool>(TaskCreationOptions.RunContinuationsAsynchronously);
        var queued = queue.TryEnqueue(async () =>
        {
            try
            {
                opened.TrySetResult(await Launcher.LaunchUriAsync(url));
            }
            catch (Exception exception)
            {
                opened.TrySetException(exception);
            }
        });
        if (!queued)
        {
            opened.TrySetResult(false);
        }

        return opened.Task;
    }
}
