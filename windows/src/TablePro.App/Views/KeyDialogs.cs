using System.Runtime.InteropServices;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Media;
using TablePro.App.Model;
using TablePro.App.Services;
using TablePro.Interop;
using Windows.ApplicationModel.DataTransfer;
using Windows.System;

namespace TablePro.App.Views;

public enum KeyDialogResult
{
    Closed,
    Done,

    // The flow ended where another device's approval is the way on.
    AskForApproval,
}

// The end-to-end key flows' dialogs (docs/decisions/0030-end-to-end-encryption.md), one ContentDialog each, its content
// laid out again as the flow moves; the flow keeps the state and the core does the work.
internal static class KeyDialogs
{
    private static readonly FontFamily Monospace = new("Cascadia Mono, Consolas, Courier New");

    public static async Task<KeyDialogResult> RecoveryKeyAsync(
        FrameworkElement owner,
        Workbench workbench,
        RecoveryKeyPurpose purpose)
    {
        ArgumentNullException.ThrowIfNull(owner);
        ArgumentNullException.ThrowIfNull(workbench);
        var flow = new RecoveryKeyFlow(purpose, workbench.Sync.GetKeyFlowsAsync);
        var dialog = Dialog(owner, "RecoveryKeyDialog");
        var result = KeyDialogResult.Closed;

        void Render()
        {
            var replace = purpose == RecoveryKeyPurpose.Replace;
            var body = new StackPanel { Spacing = 12, MaxWidth = 480 };
            dialog.SecondaryButtonText = string.Empty;
            dialog.CloseButtonText = Strings.Get("Cancel");
            switch (flow.Step)
            {
                case RecoveryKeyStep.EnterCurrentKey:
                    dialog.Title = Strings.Get("KeysReplaceTitle");
                    body.Children.Add(Paragraph(Strings.Get("KeysReplaceMessage")));
                    body.Children.Add(KeyBox(flow.CurrentKey, text =>
                    {
                        flow.CurrentKey = text;
                        dialog.IsPrimaryButtonEnabled = flow.CanContinue;
                    }));
                    dialog.PrimaryButtonText = Strings.Get("KeysContinue");
                    break;
                case RecoveryKeyStep.ChooseDevices:
                    dialog.Title = Strings.Get("KeysKeepDevicesTitle");
                    body.Children.Add(Paragraph(Strings.Get("KeysKeepDevicesMessage")));
                    foreach (var device in flow.Devices)
                    {
                        body.Children.Add(KeepBox(device, RecoveryKeyFlow.CanKeep(device), flow.Keeps(device), kept =>
                            flow.SetKeep(device, kept)));
                    }

                    dialog.PrimaryButtonText = Strings.Get("KeysContinue");
                    break;
                case RecoveryKeyStep.ShowKey:
                    dialog.Title = Strings.Get(replace ? "KeysNewKeyTitle" : "KeysSetUpTitle");
                    body.Children.Add(Paragraph(Strings.Get("KeysSaveKeyMessage")));
                    if (flow.HasKey)
                    {
                        body.Children.Add(KeyGroups(flow.Groups));
                        body.Children.Add(CopyButton(string.Join('-', flow.Groups)));
                    }
                    else if (!flow.IsWorking && flow.Failure is not null)
                    {
                        body.Children.Add(Retry(() => _ = flow.StartAsync()));
                    }
                    else
                    {
                        body.Children.Add(Working(Strings.Get("KeysMakingKey")));
                    }

                    dialog.PrimaryButtonText = Strings.Get("KeysContinue");
                    break;
                case RecoveryKeyStep.TypeBack:
                    dialog.Title = Strings.Get("KeysConfirmKeyTitle");
                    body.Children.Add(Paragraph(KeysText.TypeBack(flow.Check)));
                    for (var position = 0; position < flow.Check.Count && position < 2; position++)
                    {
                        var index = position;
                        body.Children.Add(GroupBox(flow.Check[index], flow.Typed[index], text =>
                        {
                            flow.SetTyped(index, text);
                            dialog.IsPrimaryButtonEnabled = flow.CanContinue;
                        }));
                    }

                    dialog.SecondaryButtonText = Strings.Get("KeysShowKeyAgain");
                    dialog.PrimaryButtonText = Strings.Get(replace ? "KeysReplace" : "KeysSetUp");
                    break;
                case RecoveryKeyStep.AnotherDeviceWon:
                    dialog.Title = Strings.Get("KeysAnotherDeviceWonTitle");
                    body.Children.Add(Paragraph(Strings.Get("KeysAnotherDeviceWonMessage")));
                    dialog.PrimaryButtonText = Strings.Get("KeysAskAnotherDevice");
                    dialog.CloseButtonText = Strings.Get("KeysClose");
                    break;
                default:
                    dialog.Title = Strings.Get(replace ? "KeysReplacedTitle" : "KeysSetUpDoneTitle");
                    body.Children.Add(Paragraph(Strings.Get(replace ? "KeysReplacedMessage" : "KeysSetUpDoneMessage")));
                    dialog.PrimaryButtonText = string.Empty;
                    dialog.CloseButtonText = Strings.Get("KeysDone");
                    break;
            }

            AddFailure(body, flow.Failure);
            if (flow.IsWorking && flow.Step != RecoveryKeyStep.ShowKey)
            {
                body.Children.Add(Working(Strings.Get("KeysWorking")));
            }

            dialog.Content = new ScrollViewer { Content = body, MaxHeight = 560 };
            dialog.IsPrimaryButtonEnabled = flow.CanContinue;
        }

        flow.Changed += (_, _) => Render();
        dialog.PrimaryButtonClick += async (_, args) =>
        {
            if (flow.Step == RecoveryKeyStep.AnotherDeviceWon)
            {
                result = KeyDialogResult.AskForApproval;
                return;
            }

            args.Cancel = true;
            var deferral = args.GetDeferral();
            try
            {
                await flow.AdvanceAsync().ConfigureAwait(true);
            }
            finally
            {
                deferral.Complete();
            }
        };
        dialog.SecondaryButtonClick += (_, args) =>
        {
            args.Cancel = true;
            flow.ShowKeyAgain();
        };
        dialog.Opened += async (_, _) => await flow.StartAsync().ConfigureAwait(true);
        Render();
        await WindowDialogs.ShowAsync(dialog, owner).ConfigureAwait(true);
        var done = flow.Step == RecoveryKeyStep.Done;
        await flow.DiscardAsync().ConfigureAwait(true);
        return result == KeyDialogResult.AskForApproval ? result : done ? KeyDialogResult.Done : KeyDialogResult.Closed;
    }

    // Recovery with the recovery key, when no approved device is at hand.
    public static async Task<KeyDialogResult> RecoverAsync(FrameworkElement owner, Workbench workbench)
    {
        ArgumentNullException.ThrowIfNull(owner);
        ArgumentNullException.ThrowIfNull(workbench);
        var flow = new RecoverFlow(workbench.Sync.GetKeyFlowsAsync);
        var dialog = Dialog(owner, "RecoverDialog");

        void Render()
        {
            var body = new StackPanel { Spacing = 12, MaxWidth = 480 };
            if (flow.IsDone)
            {
                dialog.Title = Strings.Get("KeysApprovedTitle");
                body.Children.Add(Paragraph(Strings.Get("KeysRecoveredMessage")));
                dialog.PrimaryButtonText = string.Empty;
                dialog.CloseButtonText = Strings.Get("KeysDone");
            }
            else
            {
                dialog.Title = Strings.Get("KeysRecoverTitle");
                body.Children.Add(Paragraph(Strings.Get("KeysRecoverMessage")));
                body.Children.Add(KeyBox(flow.RecoveryKey, text =>
                {
                    flow.RecoveryKey = text;
                    dialog.IsPrimaryButtonEnabled = flow.CanRecover;
                }));
                dialog.PrimaryButtonText = Strings.Get("KeysUseRecoveryKey");
                dialog.CloseButtonText = Strings.Get("Cancel");
            }

            AddFailure(body, flow.Failure);
            if (flow.IsWorking)
            {
                body.Children.Add(Working(Strings.Get("KeysWorking")));
            }

            dialog.Content = body;
            dialog.IsPrimaryButtonEnabled = flow.CanRecover;
        }

        flow.Changed += (_, _) => Render();
        dialog.PrimaryButtonClick += async (_, args) =>
        {
            args.Cancel = true;
            var deferral = args.GetDeferral();
            try
            {
                await flow.RecoverAsync().ConfigureAwait(true);
            }
            finally
            {
                deferral.Complete();
            }
        };
        Render();
        await WindowDialogs.ShowAsync(dialog, owner).ConfigureAwait(true);
        var done = flow.IsDone;
        flow.Discard();
        return done ? KeyDialogResult.Done : KeyDialogResult.Closed;
    }

    // Either side of an approval: this computer asking (picked null), or this one approving the request picked.
    public static async Task<KeyDialogResult> ApprovalAsync(
        FrameworkElement owner,
        Workbench workbench,
        ApprovalRequest? picked,
        string? openRequest)
    {
        ArgumentNullException.ThrowIfNull(owner);
        ArgumentNullException.ThrowIfNull(workbench);
        static Task Delay(TimeSpan span, CancellationToken token) => Task.Delay(span, token);
        using var flow = picked is null
            ? new ApprovalFlow(workbench.Sync.GetKeyFlowsAsync, Delay, openRequest)
            : new ApprovalFlow(workbench.Sync.GetKeyFlowsAsync, Delay, picked);
        var other = picked is null ? string.Empty : KeysText.DeviceName(picked.DeviceName);
        var dialog = Dialog(owner, "ApprovalDialog");
        var result = KeyDialogResult.Closed;
        var timeLeft = new TextBlock { Style = Caption() };
        AutomationProperties.SetAutomationId(timeLeft, "ApprovalTimeLeft");

        void Render()
        {
            var body = new StackPanel { Spacing = 12, MaxWidth = 480 };
            dialog.Title = KeysText.ApprovalTitle(flow, other);
            if (KeysText.ApprovalMessage(flow, other) is { Length: > 0 } message)
            {
                body.Children.Add(Paragraph(message));
            }

            dialog.PrimaryButtonText = string.Empty;
            dialog.SecondaryButtonText = string.Empty;
            dialog.CloseButtonText = Strings.Get(flow.HasEnded ? "KeysDone" : "Cancel");
            switch (flow.Step)
            {
                case ApprovalStep.Reviewing when picked is not null:
                    body.Children.Add(Paragraph(Strings.Format(
                        "KeysRequestDetail",
                        KeysText.Platform(picked.Platform) ?? string.Empty,
                        picked.RequestedAt.LocalDateTime)));
                    dialog.PrimaryButtonText = Strings.Get("KeysApprove");
                    break;
                case ApprovalStep.Starting or ApprovalStep.Waiting or ApprovalStep.Chosen or ApprovalStep.Confirmed:
                    body.Children.Add(Working(Strings.Get(flow.Step switch
                    {
                        ApprovalStep.Waiting => "KeysWaitingForDevice",
                        ApprovalStep.Chosen => "KeysWaitingForWords",
                        ApprovalStep.Confirmed => "KeysWaitingForConfirm",
                        _ => "KeysWorking",
                    })));
                    body.Children.Add(timeLeft);
                    break;
                case ApprovalStep.Compare:
                    body.Children.Add(Words(flow.Words));
                    body.Children.Add(timeLeft);
                    dialog.PrimaryButtonText = Strings.Get("KeysWordsMatch");
                    dialog.SecondaryButtonText = Strings.Get("KeysWordsDiffer");
                    break;
                case ApprovalStep.Cancelled or ApprovalStep.Expired when picked is null:
                    dialog.PrimaryButtonText = Strings.Get("KeysAskAgain");
                    dialog.CloseButtonText = Strings.Get("KeysClose");
                    break;
            }

            if (!flow.HasEnded)
            {
                AddFailure(body, flow.Failure);
            }

            dialog.Content = body;
            dialog.IsPrimaryButtonEnabled = !flow.IsWorking;
            dialog.IsSecondaryButtonEnabled = !flow.IsWorking;
            ShowTimeLeft();
        }

        void ShowTimeLeft() => timeLeft.Text = flow.ExpiresAt is { } expires
            ? KeysText.TimeLeft(expires, DateTimeOffset.Now)
            : string.Empty;

        var clock = owner.DispatcherQueue.CreateTimer();
        clock.Interval = TimeSpan.FromSeconds(1);
        clock.Tick += (_, _) => ShowTimeLeft();
        flow.Changed += (_, _) => Render();
        dialog.PrimaryButtonClick += async (_, args) =>
        {
            if (flow.Step is ApprovalStep.Cancelled or ApprovalStep.Expired && picked is null)
            {
                result = KeyDialogResult.AskForApproval;
                return;
            }

            args.Cancel = true;
            var deferral = args.GetDeferral();
            try
            {
                await (flow.Step == ApprovalStep.Reviewing ? flow.ApproveAsync() : flow.WordsMatchAsync())
                    .ConfigureAwait(true);
            }
            finally
            {
                deferral.Complete();
            }
        };
        dialog.SecondaryButtonClick += async (_, args) =>
        {
            args.Cancel = true;
            var deferral = args.GetDeferral();
            try
            {
                await flow.WordsDifferAsync().ConfigureAwait(true);
            }
            finally
            {
                deferral.Complete();
            }
        };
        dialog.Opened += async (_, _) =>
        {
            clock.Start();
            await flow.StartAsync().ConfigureAwait(true);
        };
        Render();
        await WindowDialogs.ShowAsync(dialog, owner).ConfigureAwait(true);
        clock.Stop();
        var approved = flow.Step == ApprovalStep.Approved;
        await flow.CloseAsync().ConfigureAwait(true);
        return result == KeyDialogResult.AskForApproval ? result : approved ? KeyDialogResult.Done : KeyDialogResult.Closed;
    }

    // Removing a lost device once its row is gone: the recovery key, the review, the seats, then the new keys.
    public static async Task<KeyDialogResult> RemovalAsync(FrameworkElement owner, Workbench workbench, KeyDevice lost)
    {
        ArgumentNullException.ThrowIfNull(owner);
        ArgumentNullException.ThrowIfNull(workbench);
        ArgumentNullException.ThrowIfNull(lost);
        var flow = new RemovalFlow(lost, workbench.Sync.GetKeyFlowsAsync);
        var name = KeysText.DeviceName(lost.Name);
        var dialog = Dialog(owner, "RemovalDialog");

        void Render()
        {
            var body = new StackPanel { Spacing = 12, MaxWidth = 520 };
            dialog.SecondaryButtonText = string.Empty;
            dialog.CloseButtonText = Strings.Get("KeysLater");
            switch (flow.Step)
            {
                case RemovalStep.EnterKey:
                    dialog.Title = Strings.Format("KeysRemovalTitle", name);
                    body.Children.Add(Paragraph(Strings.Get("KeysRemovalMessage")));
                    body.Children.Add(KeyBox(flow.RecoveryKey, text =>
                    {
                        flow.RecoveryKey = text;
                        dialog.IsPrimaryButtonEnabled = flow.CanContinue;
                    }));
                    dialog.PrimaryButtonText = Strings.Get("KeysContinue");
                    break;
                case RemovalStep.Review:
                    dialog.Title = Strings.Get("KeysReviewTitle");
                    body.Children.Add(Paragraph(Strings.Get("KeysReviewMessage")));
                    body.Children.Add(Heading(Strings.Get("KeysYourDevices")));
                    foreach (var device in flow.Review?.Devices ?? [])
                    {
                        body.Children.Add(KeepBox(device, flow.CanKeep(device), flow.Keeps(device), kept =>
                            flow.SetKeep(device, kept)));
                    }

                    foreach (var team in flow.Teams)
                    {
                        body.Children.Add(Heading(KeysText.Team(team.Name)));
                        body.Children.Add(Paragraph(Strings.Format("KeysConfirmedWhile", name)));
                        foreach (var member in team.Members)
                        {
                            var box = new CheckBox
                            {
                                Content = KeysText.Member(member),
                                IsChecked = !flow.Removes(member),
                                IsEnabled = !member.IsSelf,
                            };
                            box.Checked += (_, _) => flow.SetRemoving(member, false);
                            box.Unchecked += (_, _) => flow.SetRemoving(member, true);
                            body.Children.Add(box);
                        }
                    }

                    dialog.PrimaryButtonText = Strings.Get(flow.Teams.Any(team => team.Members.Any(flow.Removes))
                        ? "KeysContinue"
                        : "KeysChangeKeys");
                    break;
                case RemovalStep.Seats:
                    dialog.Title = Strings.Get("KeysSeatsTitle");
                    body.Children.Add(Paragraph(Strings.Get("KeysSeatsMessage")));
                    foreach (var team in flow.TeamsToVisit)
                    {
                        var row = new Grid { ColumnSpacing = 12 };
                        row.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
                        row.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
                        row.Children.Add(new TextBlock { Text = KeysText.Team(team.Name), VerticalAlignment = VerticalAlignment.Center });
                        var manage = new Button { Content = Strings.Get("KeysManageTeam") };
                        var link = new Uri(workbench.Portal, "teams/" + Uri.EscapeDataString(team.Team));
                        manage.Click += async (_, _) => await Launcher.LaunchUriAsync(link);
                        Grid.SetColumn(manage, 1);
                        row.Children.Add(manage);
                        body.Children.Add(row);
                    }

                    dialog.SecondaryButtonText = Strings.Get("KeysBack");
                    dialog.PrimaryButtonText = Strings.Get("KeysChangeKeys");
                    break;
                default:
                    dialog.Title = Strings.Format("KeysRemovedTitle", name);
                    body.Children.Add(Paragraph(Strings.Get("KeysRemovedMessage")));
                    dialog.PrimaryButtonText = string.Empty;
                    dialog.CloseButtonText = Strings.Get("KeysDone");
                    break;
            }

            if (flow.Failure is { } failure)
            {
                AddFailure(body, failure, flow.FailedRotation ? Strings.Get("KeysRemovalTryAgain") : null);
            }

            if (flow.IsWorking)
            {
                body.Children.Add(Working(Strings.Get("KeysWorking")));
            }

            dialog.Content = new ScrollViewer { Content = body, MaxHeight = 560 };
            dialog.IsPrimaryButtonEnabled = flow.CanContinue;
        }

        flow.Changed += (_, _) => Render();
        dialog.PrimaryButtonClick += async (_, args) =>
        {
            args.Cancel = true;
            var deferral = args.GetDeferral();
            try
            {
                await flow.AdvanceAsync().ConfigureAwait(true);
            }
            finally
            {
                deferral.Complete();
            }
        };
        dialog.SecondaryButtonClick += (_, args) =>
        {
            args.Cancel = true;
            flow.BackToReview();
        };
        Render();
        await WindowDialogs.ShowAsync(dialog, owner).ConfigureAwait(true);
        var done = flow.Step == RemovalStep.Done;
        await flow.DiscardAsync().ConfigureAwait(true);
        return done ? KeyDialogResult.Done : KeyDialogResult.Closed;
    }

    // A reset proposal: what it does, the new recovery key, two groups typed back, then the proposal goes up.
    public static async Task<KeyDialogResult> ResetAsync(FrameworkElement owner, Workbench workbench, ResetKind kind)
    {
        ArgumentNullException.ThrowIfNull(owner);
        ArgumentNullException.ThrowIfNull(workbench);
        var proposal = new ResetProposal(kind, workbench.Sync.GetKeyFlowsAsync, workbench.StepUp);
        var dialog = Dialog(owner, "ResetDialog");

        void Render()
        {
            var body = new StackPanel { Spacing = 12, MaxWidth = 480 };
            dialog.SecondaryButtonText = string.Empty;
            dialog.CloseButtonText = Strings.Get("Cancel");
            switch (proposal.Step)
            {
                case ResetProposalStep.Explain or ResetProposalStep.Preparing:
                    dialog.Title = Strings.Get("KeysResetTitle");
                    body.Children.Add(Paragraph(Strings.Get("KeysResetExplain_" + kind)));
                    if (proposal.Step == ResetProposalStep.Preparing)
                    {
                        body.Children.Add(Working(Strings.Get("KeysWorking")));
                    }

                    dialog.PrimaryButtonText = Strings.Get("KeysContinue");
                    dialog.IsPrimaryButtonEnabled = proposal.Step == ResetProposalStep.Explain;
                    break;
                case ResetProposalStep.ShowKey:
                    dialog.Title = Strings.Get("KeysNewKeyTitle");
                    body.Children.Add(Paragraph(Strings.Get("KeysSaveKeyMessage")));
                    body.Children.Add(KeyGroups(proposal.Groups));
                    body.Children.Add(CopyButton(string.Join('-', proposal.Groups)));
                    dialog.PrimaryButtonText = Strings.Get("KeysContinue");
                    dialog.IsPrimaryButtonEnabled = true;
                    break;
                case ResetProposalStep.TypeBack or ResetProposalStep.Submitting:
                    dialog.Title = Strings.Get("KeysConfirmKeyTitle");
                    body.Children.Add(Paragraph(KeysText.TypeBack(proposal.Check)));
                    for (var position = 0; position < proposal.Check.Count && position < 2; position++)
                    {
                        var index = position;
                        body.Children.Add(GroupBox(proposal.Check[index], proposal.Typed[index], text =>
                        {
                            proposal.SetTyped(index, text);
                            dialog.IsPrimaryButtonEnabled = proposal.CanSubmit;
                        }));
                    }

                    if (proposal.Step == ResetProposalStep.Submitting)
                    {
                        body.Children.Add(Working(Strings.Get("KeysWorking")));
                    }

                    dialog.SecondaryButtonText = Strings.Get("KeysShowKeyAgain");
                    dialog.PrimaryButtonText = Strings.Get("KeysAskToReset");
                    dialog.IsPrimaryButtonEnabled = proposal.CanSubmit;
                    break;
                default:
                    dialog.Title = Strings.Get("KeysResetAskedTitle");
                    body.Children.Add(Paragraph(proposal.Proposed is { } pending
                        ? KeysText.PendingResetText(pending)
                        : Strings.Get("KeysResetAskedMessage")));
                    dialog.PrimaryButtonText = string.Empty;
                    dialog.CloseButtonText = Strings.Get("KeysDone");
                    break;
            }

            AddFailure(body, proposal.Failure);
            dialog.Content = new ScrollViewer { Content = body, MaxHeight = 560 };
        }

        proposal.Changed += (_, _) => Render();
        dialog.PrimaryButtonClick += async (_, args) =>
        {
            args.Cancel = true;
            var deferral = args.GetDeferral();
            try
            {
                switch (proposal.Step)
                {
                    case ResetProposalStep.Explain:
                        await proposal.BeginAsync().ConfigureAwait(true);
                        break;
                    case ResetProposalStep.ShowKey:
                        proposal.ContinueToTypeBack();
                        break;
                    case ResetProposalStep.TypeBack:
                        await proposal.SubmitAsync().ConfigureAwait(true);
                        break;
                }
            }
            finally
            {
                deferral.Complete();
            }
        };
        dialog.SecondaryButtonClick += (_, args) =>
        {
            args.Cancel = true;
            proposal.ShowKeyAgain();
        };
        Render();
        await WindowDialogs.ShowAsync(dialog, owner).ConfigureAwait(true);
        var done = proposal.Step == ResetProposalStep.Done;
        await proposal.CloseAsync().ConfigureAwait(true);
        return done ? KeyDialogResult.Done : KeyDialogResult.Closed;
    }

    // Null when the person closed it; the recovery key as typed otherwise.
    public static async Task<string?> AskRecoveryKeyAsync(FrameworkElement owner, string title, string message, string action)
    {
        ArgumentNullException.ThrowIfNull(owner);
        var typed = string.Empty;
        var dialog = Dialog(owner, "RecoveryKeyPromptDialog");
        dialog.Title = title;
        dialog.PrimaryButtonText = action;
        dialog.CloseButtonText = Strings.Get("Cancel");
        dialog.IsPrimaryButtonEnabled = false;
        var body = new StackPanel { Spacing = 12, MaxWidth = 480 };
        body.Children.Add(Paragraph(message));
        body.Children.Add(KeyBox(string.Empty, text =>
        {
            typed = text;
            dialog.IsPrimaryButtonEnabled = !string.IsNullOrWhiteSpace(text);
        }));
        dialog.Content = body;
        return await WindowDialogs.ShowAsync(dialog, owner).ConfigureAwait(true) == ContentDialogResult.Primary
            ? typed
            : null;
    }

    public static async Task<bool> ConfirmAsync(
        FrameworkElement owner,
        string title,
        string message,
        string action,
        string automationId)
    {
        ArgumentNullException.ThrowIfNull(owner);
        var dialog = Dialog(owner, automationId);
        dialog.Title = title;
        dialog.Content = Paragraph(message);
        dialog.PrimaryButtonText = action;
        dialog.CloseButtonText = Strings.Get("Cancel");
        dialog.DefaultButton = ContentDialogButton.Close;
        return await WindowDialogs.ShowAsync(dialog, owner).ConfigureAwait(true) == ContentDialogResult.Primary;
    }

    // Sign out's question after the keys could not be erased (core ADR 0056, Sign Out).
    public static async Task<KeysSignOutAnswer> SignOutFailedAsync(FrameworkElement owner, CoreError reason)
    {
        ArgumentNullException.ThrowIfNull(owner);
        ArgumentNullException.ThrowIfNull(reason);
        var dialog = Dialog(owner, "KeysSignOutFailedDialog");
        dialog.Title = Strings.Get("KeysSignOutFailedTitle");
        dialog.Content = Paragraph(Strings.Format("KeysSignOutFailedMessage", Strings.Error(reason)));
        dialog.PrimaryButtonText = Strings.Get("AccountTryAgain");
        dialog.SecondaryButtonText = Strings.Get("KeysSignOutAnyway");
        dialog.CloseButtonText = Strings.Get("Cancel");
        return await WindowDialogs.ShowAsync(dialog, owner).ConfigureAwait(true) switch
        {
            ContentDialogResult.Primary => KeysSignOutAnswer.TryAgain,
            ContentDialogResult.Secondary => KeysSignOutAnswer.SignOutAnyway,
            _ => KeysSignOutAnswer.Cancel,
        };
    }

    private static ContentDialog Dialog(FrameworkElement owner, string automationId)
    {
        var dialog = new ContentDialog
        {
            RequestedTheme = owner.ActualTheme,
            DefaultButton = ContentDialogButton.Primary,
        };
        AutomationProperties.SetAutomationId(dialog, automationId);
        return dialog;
    }

    private static TextBlock Paragraph(string text) => new() { Text = text, TextWrapping = TextWrapping.Wrap };

    private static TextBlock Heading(string text) =>
        new() { Text = text, Style = (Style)Application.Current.Resources["BodyStrongTextBlockStyle"] };

    private static Style Caption() => (Style)Application.Current.Resources["CaptionTextBlockStyle"];

    private static StackPanel Working(string text)
    {
        var row = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 8 };
        row.Children.Add(new ProgressRing { Width = 16, Height = 16, IsActive = true });
        row.Children.Add(new TextBlock { Text = text, VerticalAlignment = VerticalAlignment.Center });
        return row;
    }

    private static Button Retry(Action again)
    {
        var button = new Button { Content = Strings.Get("AccountTryAgain") };
        button.Click += (_, _) => again();
        return button;
    }

    private static void AddFailure(StackPanel body, CoreError? failure, string? after = null)
    {
        if (failure is null)
        {
            return;
        }

        var bar = new InfoBar
        {
            Severity = InfoBarSeverity.Error,
            Message = Strings.Sentences(Strings.Error(failure), after),
            IsClosable = false,
            IsOpen = true,
        };
        AutomationProperties.SetAutomationId(bar, "KeysDialogFailure");
        body.Children.Add(bar);
    }

    // A recovery key is a secret: typed into a password box that shows it only while asked to.
    private static PasswordBox KeyBox(string text, Action<string> typed)
    {
        var box = new PasswordBox
        {
            Password = text,
            Header = Strings.Get("KeysRecoveryKeyHeader"),
            PlaceholderText = Strings.Get("KeysRecoveryKeyPlaceholder"),
            PasswordRevealMode = PasswordRevealMode.Peek,
        };
        AutomationProperties.SetAutomationId(box, "RecoveryKeyBox");
        box.PasswordChanged += (_, _) => typed(box.Password);
        return box;
    }

    private static TextBox GroupBox(int group, string text, Action<string> typed)
    {
        var box = new TextBox
        {
            Header = KeysText.Group(group),
            Text = text,
            MaxLength = 4,
            FontFamily = Monospace,
            CharacterCasing = CharacterCasing.Upper,
            IsSpellCheckEnabled = false,
            Width = 120,
            HorizontalAlignment = HorizontalAlignment.Left,
        };
        AutomationProperties.SetAutomationId(box, "RecoveryKeyGroup" + (group + 1));
        box.TextChanged += (_, _) => typed(box.Text);
        return box;
    }

    private static CheckBox KeepBox(ReviewedDevice device, bool canKeep, bool kept, Action<bool> changed)
    {
        var label = new StackPanel();
        label.Children.Add(new TextBlock { Text = KeysText.DeviceName(device.Device.Name) });
        label.Children.Add(new TextBlock { Text = KeysText.KeepDetail(device), Style = Caption() });
        var box = new CheckBox
        {
            Content = label,
            IsChecked = device.Device.IsThisDevice || kept,
            IsEnabled = canKeep,
        };
        AutomationProperties.SetName(box, KeysText.DeviceName(device.Device.Name));
        box.Checked += (_, _) => changed(true);
        box.Unchecked += (_, _) => changed(false);
        return box;
    }

    // The 14 groups numbered, two to a row, so the two asked for are easy to find.
    private static Grid KeyGroups(IReadOnlyList<string> groups)
    {
        var grid = new Grid { ColumnSpacing = 24, RowSpacing = 4 };
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        for (var index = 0; index < groups.Count; index++)
        {
            if (index % 2 == 0)
            {
                grid.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });
            }

            var cell = new TextBlock
            {
                Text = Strings.Format("KeysGroupLine", index + 1, groups[index]),
                FontFamily = Monospace,
                IsTextSelectionEnabled = true,
            };
            Grid.SetRow(cell, index / 2);
            Grid.SetColumn(cell, index % 2);
            grid.Children.Add(cell);
        }

        AutomationProperties.SetAutomationId(grid, "RecoveryKeyGroups");
        AutomationProperties.SetName(grid, Strings.Get("KeysRecoveryKeyHeader"));
        return grid;
    }

    // Kept out of the clipboard's history and off other devices, since it unlocks the account's keys.
    private static StackPanel CopyButton(string key)
    {
        var row = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 12 };
        var button = new Button { Content = Strings.Get("KeysCopy") };
        AutomationProperties.SetName(button, Strings.Get("KeysCopyName"));
        var note = new TextBlock { VerticalAlignment = VerticalAlignment.Center, Style = Caption() };
        AutomationProperties.SetLiveSetting(note, Microsoft.UI.Xaml.Automation.Peers.AutomationLiveSetting.Polite);
        button.Click += (_, _) =>
        {
            var package = new DataPackage();
            package.SetText(key);
            try
            {
                Clipboard.SetContentWithOptions(
                    package,
                    new ClipboardContentOptions { IsAllowedInHistory = false, IsRoamable = false });
                note.Text = Strings.Get("KeysCopied");
            }
            catch (COMException)
            {
                note.Text = Strings.Get("McpCopyFailed");
            }
        };
        row.Children.Add(button);
        row.Children.Add(note);
        return row;
    }

    private static Border Words(IReadOnlyList<string> words)
    {
        var text = new TextBlock
        {
            Text = Strings.List(words),
            Style = (Style)Application.Current.Resources["SubtitleTextBlockStyle"],
            TextWrapping = TextWrapping.Wrap,
            IsTextSelectionEnabled = true,
        };
        AutomationProperties.SetAutomationId(text, "ApprovalWords");
        AutomationProperties.SetName(text, Strings.Format("KeysWordsName", Strings.List(words)));
        return new Border { Child = text, Padding = new Thickness(0, 8, 0, 8) };
    }
}
