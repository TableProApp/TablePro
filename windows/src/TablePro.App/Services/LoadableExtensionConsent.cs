using TablePro.Core.Connections;
using TablePro.Storage.Connections;

namespace TablePro.App.Services;

/// <summary>
/// A connect refused because the connection lists SQLite extensions this PC has not approved. Every route that
/// connects meets it, from the welcome window to a reconnect, MCP, Compare and Copy; only the welcome window asks.
/// </summary>
public sealed class LoadableExtensionApprovalException : Exception
{
    public LoadableExtensionApprovalException()
        : this([])
    {
    }

    public LoadableExtensionApprovalException(string message)
        : base(message)
    {
        Pending = [];
    }

    public LoadableExtensionApprovalException(string message, Exception innerException)
        : base(message, innerException)
    {
        Pending = [];
    }

    public LoadableExtensionApprovalException(IReadOnlyList<LoadableExtension> pending)
        : base(string.Join("\n\n", Strings.Get("Extensions/NotApproved"), ExtensionNames.Files(pending), Strings.Get("Extensions/NotApprovedRecovery")))
    {
        Pending = pending;
    }

    public IReadOnlyList<LoadableExtension> Pending { get; }
}

/// <summary>
/// Asks before a connect loads SQLite extensions this PC has not approved for the connection, which is every list
/// that arrived through an import or the team library rather than being added in the connection form here. It names
/// each file, because the person is agreeing to run that code, and records the answer so the same list asks once.
/// </summary>
internal static class LoadableExtensionConsent
{
    public static async Task<bool> ConfirmAsync(DialogService dialogs, LoadableExtensionApprovalStore approvals, ConnectionProfile profile)
    {
        var pending = approvals.Pending(profile);
        if (pending.Count == 0)
        {
            return true;
        }

        if (!await dialogs.ConfirmAsync(Strings.Get("Extensions/PromptTitle"), Message(profile, pending), Strings.Get("Extensions/PromptConfirm")))
        {
            return false;
        }

        await approvals.ApproveAsync(pending, profile.Id);
        return true;
    }

    public static string Message(ConnectionProfile profile, IReadOnlyList<LoadableExtension> pending) => string.Join(
        "\n\n",
        Strings.Format("Extensions/PromptIntro", ExtensionNames.SingleLine(profile.Name)),
        ExtensionNames.Files(pending),
        Strings.Get("Extensions/PromptWarning"));
}
