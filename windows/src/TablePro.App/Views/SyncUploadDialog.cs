using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Controls;
using TablePro.App.Model;
using TablePro.App.Services;
using TablePro.Interop;

namespace TablePro.App.Views;

// The first upload to TablePro Sync: what goes up and what stays, then the upload (core ADR 0054, Moving between
// providers). Nothing goes up before the person confirms here, and nothing under another sign-in than this one's.
internal static class SyncUploadDialog
{
    public static async Task ShowAsync(FrameworkElement owner, Workbench workbench)
    {
        ArgumentNullException.ThrowIfNull(owner);
        ArgumentNullException.ThrowIfNull(workbench);
        var signIn = workbench.SignInId;
        var progress = new ProgressRing { Width = 16, Height = 16, IsActive = true };
        var progressText = new TextBlock
        {
            Text = Strings.Get("SyncUploadChecking"),
            VerticalAlignment = VerticalAlignment.Center,
        };
        var progressRow = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 8 };
        progressRow.Children.Add(progress);
        progressRow.Children.Add(progressText);
        var counts = new StackPanel { Spacing = 4, Visibility = Visibility.Collapsed };
        AutomationProperties.SetAutomationId(counts, "SyncUploadPlan");
        var notice = new InfoBar { IsClosable = false, Visibility = Visibility.Collapsed };
        AutomationProperties.SetAutomationId(notice, "SyncUploadNotice");
        var content = new StackPanel { Spacing = 12, MaxWidth = 480 };
        content.Children.Add(new TextBlock { Text = Strings.Get("SyncUploadExplained"), TextWrapping = TextWrapping.Wrap });
        content.Children.Add(progressRow);
        content.Children.Add(counts);
        content.Children.Add(notice);
        var dialog = new ContentDialog
        {
            RequestedTheme = owner.ActualTheme,
            Title = Strings.Get("SyncUploadTitle"),
            Content = content,
            PrimaryButtonText = Strings.Get("SyncUploadButton"),
            CloseButtonText = Strings.Get("Cancel"),
            DefaultButton = ContentDialogButton.Primary,
            IsPrimaryButtonEnabled = false,
        };
        AutomationProperties.SetAutomationId(dialog, "SyncUploadDialog");

        void Busy(string? text)
        {
            progressRow.Visibility = text is null ? Visibility.Collapsed : Visibility.Visible;
            progress.IsActive = text is not null;
            progressText.Text = text ?? string.Empty;
        }

        void Say(InfoBarSeverity severity, string message)
        {
            notice.Severity = severity;
            notice.Message = message;
            notice.Visibility = Visibility.Visible;
            notice.IsOpen = true;
        }

        async Task<bool> PlanAsync()
        {
            Busy(Strings.Get("SyncUploadChecking"));
            try
            {
                var plan = await workbench.Sync.PlanUploadAsync().ConfigureAwait(true);
                ShowCounts(counts, plan);
                return true;
            }
            catch (TableProException exception)
            {
                CrashLog.Note("sync upload plan", exception.Code);
                Say(InfoBarSeverity.Error, Strings.Error(exception.Error));
                return false;
            }
            finally
            {
                Busy(null);
            }
        }

        var planned = false;
        dialog.PrimaryButtonClick += async (_, args) =>
        {
            var deferral = args.GetDeferral();
            dialog.IsPrimaryButtonEnabled = false;
            notice.Visibility = Visibility.Collapsed;
            notice.IsOpen = false;
            try
            {
                if (!planned)
                {
                    planned = await PlanAsync().ConfigureAwait(true);
                    args.Cancel = true;
                    return;
                }

                Busy(Strings.Get("SyncUploadUploading"));
                var outcome = await workbench.Sync.UploadAsync(signIn).ConfigureAwait(true);
                Busy(null);
                switch (outcome)
                {
                    case UploadOutcome.Uploaded:
                        return;
                    case UploadOutcome.NeedsKeys needs:
                        Say(InfoBarSeverity.Informational, NeedsKeysText(needs.State));
                        dialog.PrimaryButtonText = Strings.Get("SyncUploadCheckAgain");
                        break;
                    case UploadOutcome.Refused refused:
                        Say(InfoBarSeverity.Error, SyncText.Refusal(refused.Reason));
                        break;
                    case UploadOutcome.Failed failed:
                        CrashLog.Note("sync upload", failed.Error.Code);
                        Say(InfoBarSeverity.Error, Strings.Error(failed.Error));
                        dialog.PrimaryButtonText = Strings.Get("AccountTryAgain");
                        break;
                }

                args.Cancel = true;
            }
            finally
            {
                dialog.IsPrimaryButtonEnabled = true;
                deferral.Complete();
            }
        };
        dialog.Opened += async (_, _) =>
        {
            planned = await PlanAsync().ConfigureAwait(true);
            dialog.PrimaryButtonText = Strings.Get(planned ? "SyncUploadButton" : "AccountTryAgain");
            dialog.IsPrimaryButtonEnabled = true;
        };
        await WindowDialogs.ShowAsync(dialog, owner).ConfigureAwait(true);
    }

    private static void ShowCounts(StackPanel counts, SyncUploadPlan plan)
    {
        counts.Children.Clear();
        counts.Children.Add(Line(Strings.Plural("SyncUploadRecords", plan.Records, plan.Records)));
        if (plan.SecretsToSeal > 0)
        {
            counts.Children.Add(Line(Strings.Plural("SyncUploadSecrets", plan.SecretsToSeal, plan.SecretsToSeal)));
        }

        if (plan.StayingBehind > 0)
        {
            counts.Children.Add(Line(Strings.Plural("SyncUploadStaying", plan.StayingBehind, plan.StayingBehind)));
        }

        counts.Visibility = Visibility.Visible;
    }

    private static TextBlock Line(string text) => new() { Text = text, TextWrapping = TextWrapping.Wrap };

    // The keys come first (core ADR 0055, PersonalSyncProvider; 0056); Settings' end-to-end encryption page sets them up.
    private static string NeedsKeysText(KeyState state) =>
        UploadKeys.StepFor(state) is { } step ? SyncText.KeysStep(step) : string.Empty;
}
