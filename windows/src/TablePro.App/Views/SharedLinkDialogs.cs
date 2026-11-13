using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Media;
using TablePro.App.Model;
using TablePro.App.Services;
using TablePro.Interop;

namespace TablePro.App.Views;

// A tablepro://share link's password and messages wait for the window and any open dialog, so none is dropped.
internal static class SharedLinkDialogs
{
    // Null when the link has nothing to open or the person cancels.
    public static async Task<PublicShare?> FetchAsync(FrameworkElement owner, Workbench workbench, string link)
    {
        ArgumentNullException.ThrowIfNull(owner);
        ArgumentNullException.ThrowIfNull(workbench);
        if (ShareLinks.TokenFromLink(link) is not { } token)
        {
            await TellAsync(owner, Strings.Get("SharedLinkUnavailable")).ConfigureAwait(true);
            return null;
        }

        if (await workbench.GetAccountAsync().ConfigureAwait(true) is not { } account)
        {
            var failure = workbench.AccountFailure;
            await TellAsync(owner, failure is null ? Strings.Get("SharedLinkUnavailable") : Strings.Error(failure))
                .ConfigureAwait(true);
            return null;
        }

        string? password = null;
        while (true)
        {
            PublicShare shared;
            try
            {
                shared = await account.FetchSharedAsync(token, password).ConfigureAwait(true);
            }
            catch (TableProException exception)
            {
                var step = SharedLinkOpen.After(exception.Error);
                if (step is SharedLinkStep.AskPassword or SharedLinkStep.AskPasswordAgain)
                {
                    password = await AskPasswordAsync(owner, step == SharedLinkStep.AskPasswordAgain).ConfigureAwait(true);
                    if (password is null)
                    {
                        return null;
                    }

                    continue;
                }

                await TellAsync(
                        owner,
                        step == SharedLinkStep.Unavailable ? Strings.Get("SharedLinkUnavailable") : Strings.Error(exception.Error))
                    .ConfigureAwait(true);
                return null;
            }

            if (SharedLinkOpen.After(shared) == SharedLinkStep.HiddenSql)
            {
                await TellAsync(owner, Strings.Get("SharedLinkHidesSql")).ConfigureAwait(true);
                return null;
            }

            return shared;
        }
    }

    // No connection is open to hold a query tab, so the SQL is shown to copy; it is never run.
    public static async Task ShowWithoutConnectionAsync(FrameworkElement owner, PublicShare shared)
    {
        ArgumentNullException.ThrowIfNull(owner);
        ArgumentNullException.ThrowIfNull(shared);
        var content = new StackPanel { Spacing = 12 };
        content.Children.Add(new TextBlock { Text = Strings.Get("SharedLinkNoConnection"), TextWrapping = TextWrapping.Wrap });
        var sql = new TextBlock
        {
            Text = shared.Sql,
            FontFamily = new FontFamily("Cascadia Mono, Consolas, Courier New"),
            TextWrapping = TextWrapping.Wrap,
            IsTextSelectionEnabled = true,
        };
        AutomationProperties.SetAutomationId(sql, "SharedLinkSql");
        content.Children.Add(sql);
        var dialog = new ContentDialog
        {
            RequestedTheme = owner.ActualTheme,
            Title = SharedLinkOpen.TabTitle(shared, Strings.Get("SharedQueryTitle")),
            Content = new ScrollViewer { Content = content, MaxHeight = 480 },
            PrimaryButtonText = Strings.Get("SharedLinkCopySql"),
            CloseButtonText = Strings.Get("Close"),
            DefaultButton = ContentDialogButton.Primary,
        };
        if (await WindowDialogs.ShowWhenFreeAsync(dialog, owner).ConfigureAwait(true) == ContentDialogResult.Primary)
        {
            WorkspaceView.CopyText(shared.Sql ?? string.Empty);
        }
    }

    private static async Task<string?> AskPasswordAsync(FrameworkElement owner, bool wrong)
    {
        var content = new StackPanel { Spacing = 12 };
        if (wrong)
        {
            content.Children.Add(new InfoBar
            {
                Severity = InfoBarSeverity.Error,
                Message = Strings.Get("SharedLinkPasswordWrong"),
                IsClosable = false,
                IsOpen = true,
            });
        }

        var box = new PasswordBox { Header = Strings.Get("SharePasswordField"), MaxLength = 128 };
        AutomationProperties.SetAutomationId(box, "SharedLinkPassword");
        content.Children.Add(box);
        var dialog = new ContentDialog
        {
            RequestedTheme = owner.ActualTheme,
            Title = Strings.Get("SharedLinkPasswordTitle"),
            Content = content,
            PrimaryButtonText = Strings.Get("SharedLinkOpenButton"),
            CloseButtonText = Strings.Get("Cancel"),
            DefaultButton = ContentDialogButton.Primary,
            IsPrimaryButtonEnabled = false,
        };
        box.PasswordChanged += (_, _) => dialog.IsPrimaryButtonEnabled = box.Password.Length > 0;
        dialog.Opened += (_, _) => box.Focus(FocusState.Programmatic);
        return await WindowDialogs.ShowWhenFreeAsync(dialog, owner).ConfigureAwait(true) == ContentDialogResult.Primary
            ? box.Password
            : null;
    }

    private static Task<ContentDialogResult> TellAsync(FrameworkElement owner, string message) =>
        WindowDialogs.ShowWhenFreeAsync(
            new ContentDialog
            {
                RequestedTheme = owner.ActualTheme,
                Title = Strings.Get("SharedLinkTitle"),
                Content = new TextBlock { Text = message, TextWrapping = TextWrapping.Wrap },
                CloseButtonText = Strings.Get("Close"),
                DefaultButton = ContentDialogButton.Close,
            },
            owner);
}
