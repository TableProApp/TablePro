using System.Globalization;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Controls;
using TablePro.App.Services;
using TablePro.App.ViewModels;
using TablePro.Core.Copy;
using TablePro.Core.Schema;

namespace TablePro.App.Views;

/// <summary>
/// Copy Objects, as on macOS: pick objects and a target connection, review what each becomes there (types translated
/// across engines, keys and indexes that follow, what already exists), then run with progress and Stop, and read a
/// report of every object.
/// </summary>
public static class CopyObjectsDialog
{
    private static readonly (string Name, CopyContent Value)[] Contents =
    [
        ("Structure and data", CopyContent.StructureAndData),
        ("Structure only", CopyContent.Structure),
        ("Data only", CopyContent.Data),
    ];

    private static readonly (string Name, CopyExistingPolicy Value)[] Policies =
    [
        ("Skip it", CopyExistingPolicy.Skip),
        ("Replace it", CopyExistingPolicy.Replace),
        ("Add rows to it", CopyExistingPolicy.AppendData),
    ];

    /// <summary>Copies <paramref name="objects"/> (and any others the user adds) to a connection <paramref name="targets"/> offers.</summary>
    public static async Task ShowAsync(WorkspaceContext context, IReadOnlyList<DatabaseObject> objects, CopyTargets targets)
    {
        ArgumentNullException.ThrowIfNull(context);
        ArgumentNullException.ThrowIfNull(targets);
        var model = new CopyObjectsViewModel(context, objects ?? [], targets);
        if (!await ChooseAsync(context.Dialogs, model))
        {
            return;
        }

        try
        {
            try
            {
                if (!await model.ConnectAsync(CancellationToken.None))
                {
                    return;
                }
            }
            catch (Exception ex) when (ex is not OperationCanceledException)
            {
                await context.Dialogs.ShowErrorAsync($"Cannot connect to {model.TargetProfile.Name}", ex.Message);
                return;
            }

            if (!await ReviewAsync(context.Dialogs, model))
            {
                return;
            }

            var result = await RunAsync(context.Dialogs, model);
            targets.Copied(model.TargetProfile);
            if (result is not null)
            {
                await ReportAsync(context, model, result);
            }
        }
        finally
        {
            await model.ReleaseAsync();
        }
    }

    private static async Task<bool> ChooseAsync(DialogService dialogs, CopyObjectsViewModel model)
    {
        var list = new StackPanel { Spacing = 2 };
        var boxes = new List<CheckBox>();
        foreach (var obj in model.Objects)
        {
            var box = new CheckBox { Content = $"{obj.Name.Name}  ({obj.Kind.ToString().ToLowerInvariant()})", IsChecked = model.Selected.Contains((obj.Kind, obj.Name)), MinWidth = 0 };
            box.Click += (_, _) =>
            {
                if (box.IsChecked == true)
                {
                    model.Selected.Add((obj.Kind, obj.Name));
                }
                else
                {
                    model.Selected.Remove((obj.Kind, obj.Name));
                }
            };
            boxes.Add(box);
            list.Children.Add(box);
        }

        var all = new HyperlinkButton { Content = "Select All" };
        all.Click += (_, _) => SetAll(true);
        var none = new HyperlinkButton { Content = "Select None" };
        none.Click += (_, _) => SetAll(false);
        void SetAll(bool value)
        {
            for (var i = 0; i < boxes.Count; i++)
            {
                boxes[i].IsChecked = value;
                var obj = model.Objects[i];
                if (value)
                {
                    model.Selected.Add((obj.Kind, obj.Name));
                }
                else
                {
                    model.Selected.Remove((obj.Kind, obj.Name));
                }
            }
        }

        var selection = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 4 };
        selection.Children.Add(all);
        selection.Children.Add(none);

        var target = new ComboBox { Header = "Copy to", MinWidth = 320, ItemsSource = model.Targets.Profiles.Select((p, i) => i == 0 ? $"{p.Name} (this connection)" : $"{p.Name}  ·  {p.Descriptor.DisplayName}").ToList(), SelectedIndex = 0 };
        var refusal = new InfoBar { Severity = InfoBarSeverity.Error, IsClosable = false };
        target.SelectionChanged += (_, _) =>
        {
            model.TargetProfile = model.Targets.Profiles[Math.Max(0, target.SelectedIndex)];
            refusal.Message = model.Refusal ?? string.Empty;
            refusal.IsOpen = model.Refusal is not null;
        };

        var content = new RadioButtons { Header = "Copy", MaxColumns = 3, ItemsSource = Contents.Select(c => c.Name).ToList(), SelectedIndex = 0 };
        var policy = new RadioButtons { Header = "When the target already has an object of that name", MaxColumns = 3, ItemsSource = Policies.Select(p => p.Name).ToList(), SelectedIndex = 0 };
        var errors = new ComboBox { Header = "On error", MinWidth = 320, ItemsSource = new List<string> { "Stop at the first failure", "Skip the failed object and continue" }, SelectedIndex = 0 };

        var panel = new StackPanel { Spacing = 12, Width = 560 };
        panel.Children.Add(new TextBlock { Text = $"Objects from {model.SourceName}", Style = (Style)Application.Current.Resources["BodyStrongTextBlockStyle"] });
        panel.Children.Add(new ScrollViewer { Content = list, MaxHeight = 220 });
        panel.Children.Add(selection);
        panel.Children.Add(target);
        panel.Children.Add(refusal);
        panel.Children.Add(content);
        panel.Children.Add(policy);
        panel.Children.Add(errors);

        var dialog = dialogs.Create("Copy Objects", new ScrollViewer { Content = panel, MaxHeight = 640 }, "Next", "Cancel");
        dialog.Resources["ContentDialogMaxWidth"] = 700.0;
        dialog.PrimaryButtonClick += (_, args) => args.Cancel = model.Selected.Count == 0 || model.Refusal is not null;
        if (await dialogs.ShowAsync(dialog) != ContentDialogResult.Primary)
        {
            return false;
        }

        model.Content = Contents[Math.Max(0, content.SelectedIndex)].Value;
        model.ExistingPolicy = Policies[Math.Max(0, policy.SelectedIndex)].Value;
        model.ErrorHandling = errors.SelectedIndex == 1 ? CopyErrorHandling.SkipAndContinue : CopyErrorHandling.Stop;
        return true;
    }

    private static async Task<bool> ReviewAsync(DialogService dialogs, CopyObjectsViewModel model)
    {
        var review = new StackPanel { Spacing = 10 };
        var warnings = new InfoBar { Severity = InfoBarSeverity.Warning, IsClosable = false };
        var panel = new StackPanel { Spacing = 12, Width = 640 };
        ContentDialog? dialog = null;
        if (model.TargetSchemas.Count > 0)
        {
            var schema = new ComboBox { Header = "Target schema", MinWidth = 260, ItemsSource = model.TargetSchemas.ToList(), SelectedItem = model.TargetSchema };
            schema.SelectionChanged += async (_, _) =>
            {
                model.TargetSchema = schema.SelectedItem as string;
                await PlanAsync();
            };
            panel.Children.Add(schema);
        }

        panel.Children.Add(warnings);
        panel.Children.Add(new ScrollViewer { Content = review, MaxHeight = 420 });
        dialog = dialogs.Create($"Copy to {model.TargetProfile.Name}", panel, "Copy", "Cancel");
        dialog.Resources["ContentDialogMaxWidth"] = 760.0;
        dialog.IsPrimaryButtonEnabled = false;
        dialog.Opened += async (_, _) => await PlanAsync();
        return await dialogs.ShowAsync(dialog) == ContentDialogResult.Primary;

        async Task PlanAsync()
        {
            dialog!.IsPrimaryButtonEnabled = false;
            review.Children.Clear();
            review.Children.Add(new ProgressRing { IsActive = true, Width = 24, Height = 24, HorizontalAlignment = HorizontalAlignment.Left });
            CopyPlan plan;
            try
            {
                plan = await model.PlanAsync(CancellationToken.None);
            }
            catch (Exception ex) when (ex is not OperationCanceledException)
            {
                review.Children.Clear();
                warnings.Severity = InfoBarSeverity.Error;
                warnings.Message = ex.Message;
                warnings.IsOpen = true;
                return;
            }

            review.Children.Clear();
            warnings.Severity = InfoBarSeverity.Warning;
            warnings.Message = string.Join("\n", plan.Warnings);
            warnings.IsOpen = plan.Warnings.Count > 0;
            if (plan.CrossesEngines && plan.Warnings.Count == 0)
            {
                review.Children.Add(Caption($"{model.SourceName} and {model.TargetProfile.Name} are different engines, so column types are translated. Check them before copying."));
            }

            foreach (var table in plan.Tables)
            {
                review.Children.Add(Entry(ActionText(table.Action, model.Content), table.Target.ToString(), table.Notes, plan.CrossesEngines && table.Action is CopyAction.Create or CopyAction.Replace && model.Content != CopyContent.Data
                    ? table.Structure.Columns.OrderBy(s => s.Ordinal).Zip(table.Columns, (source, target) => $"{target.Name}: {source.DataType} → {target.DataType}")
                    : []));
            }

            foreach (var definition in plan.Definitions)
            {
                review.Children.Add(Entry(ActionText(definition.Action, CopyContent.Structure), definition.Target.ToString(), definition.Notes, []));
            }

            dialog.IsPrimaryButtonEnabled = !plan.IsEmpty;
        }
    }

    private static string ActionText(CopyAction action, CopyContent content) => action switch
    {
        CopyAction.Create => "Create",
        CopyAction.Replace => content == CopyContent.Data ? "Empty and fill" : "Replace",
        CopyAction.Append => "Add rows to",
        _ => "Skip",
    };

    private static StackPanel Entry(string action, string name, IEnumerable<string> notes, IEnumerable<string> types)
    {
        var entry = new StackPanel { Spacing = 2 };
        var title = new TextBlock { TextWrapping = TextWrapping.Wrap };
        title.Inlines.Add(new Microsoft.UI.Xaml.Documents.Run { Text = action + " ", FontWeight = Microsoft.UI.Text.FontWeights.SemiBold });
        title.Inlines.Add(new Microsoft.UI.Xaml.Documents.Run { Text = name });
        entry.Children.Add(title);
        foreach (var line in types.Concat(notes))
        {
            entry.Children.Add(Caption(line));
        }

        return entry;
    }

    private static TextBlock Caption(string text) => new() { Text = text, TextWrapping = TextWrapping.Wrap, Style = (Style)Application.Current.Resources["CaptionTextBlockStyle"], Opacity = 0.8 };

    private static async Task<CopyResult?> RunAsync(DialogService dialogs, CopyObjectsViewModel model)
    {
        using var cancellation = new CancellationTokenSource();
        var bar = new ProgressBar { MinWidth = 440, IsIndeterminate = true };
        var phase = new TextBlock { Text = "Starting…", TextTrimming = TextTrimming.CharacterEllipsis };
        var rows = new TextBlock { Style = (Style)Application.Current.Resources["CaptionTextBlockStyle"] };
        AutomationProperties.SetName(bar, "Copy progress");
        var panel = new StackPanel { Spacing = 12 };
        panel.Children.Add(phase);
        panel.Children.Add(bar);
        panel.Children.Add(rows);
        var progressDialog = dialogs.Create("Copying", panel, null, "Stop");
        progressDialog.CloseButtonClick += (_, _) => cancellation.Cancel();
        var progress = new Progress<CopyProgress>(p =>
        {
            phase.Text = p.Phase switch
            {
                CopyPhase.Dropping => $"Dropping {p.Object}",
                CopyPhase.Creating => $"Creating {p.Object}",
                CopyPhase.CopyingRows => $"Copying rows of {p.Object}",
                CopyPhase.Indexing => $"Indexing {p.Object}",
                CopyPhase.LinkingKeys => $"Adding the keys of {p.Object}",
                CopyPhase.Definitions => $"Creating {p.Object}",
                CopyPhase.Finished => "Finishing",
                _ => "Preparing",
            };
            var counted = p.Phase == CopyPhase.CopyingRows && p.ObjectTotal is > 0;
            bar.IsIndeterminate = !counted;
            if (counted)
            {
                bar.Maximum = p.ObjectTotal!.Value;
                bar.Value = Math.Min(p.ObjectTotal.Value, p.ObjectRows ?? 0);
            }

            rows.Text = string.Create(CultureInfo.CurrentCulture, $"{p.RowsCopied:N0} rows copied");
        });

        // Hide does nothing to a dialog that has not opened yet, so a quick copy waits for it to open before closing it.
        var opened = new TaskCompletionSource();
        progressDialog.Opened += (_, _) => opened.TrySetResult();
        var shown = dialogs.ShowAsync(progressDialog);
        await opened.Task;
        CopyResult? result = null;
        Exception? failure = null;
        try
        {
            // The runner reports a failed object in its result; what reaches here is a failure of the run itself.
            result = await model.RunAsync(progress, cancellation.Token);
        }
        catch (Exception ex) when (ex is not OperationCanceledException)
        {
            failure = ex;
        }
        finally
        {
            progressDialog.Hide();
            await shown;
        }

        if (failure is not null)
        {
            await dialogs.ShowErrorAsync("Copy failed", failure.Message);
        }

        return result;
    }

    private static async Task ReportAsync(WorkspaceContext context, CopyObjectsViewModel model, CopyResult result)
    {
        var summary = string.Create(CultureInfo.CurrentCulture, $"{result.RowsCopied:N0} rows copied to {model.TargetProfile.Name}.");
        if (result.Succeeded && result.Outcomes.All(o => o.Status == CopyOutcomeStatus.Copied))
        {
            context.Notify($"Copied {result.Outcomes.Count} objects. {summary}");
            return;
        }

        var list = new StackPanel { Spacing = 10 };
        foreach (var outcome in result.Outcomes)
        {
            var status = outcome.Status switch
            {
                CopyOutcomeStatus.Copied => "Copied",
                CopyOutcomeStatus.Skipped => "Skipped",
                CopyOutcomeStatus.Cancelled => "Stopped",
                _ => "Failed",
            };
            var rows = outcome.RowsCopied > 0 ? string.Create(CultureInfo.CurrentCulture, $", {outcome.RowsCopied:N0} rows") : string.Empty;
            var lines = outcome.Error is null ? outcome.Notes : [outcome.Error, .. outcome.Notes];
            list.Children.Add(Entry(status, outcome.Name + rows, lines, []));
        }

        var panel = new StackPanel { Spacing = 12, Width = 600 };
        panel.Children.Add(new TextBlock { Text = summary, TextWrapping = TextWrapping.Wrap });
        panel.Children.Add(new ScrollViewer { Content = list, MaxHeight = 420 });
        var title = result.Cancelled ? "Copy stopped" : result.Succeeded ? "Copy finished" : "Copy finished with problems";
        var dialog = context.Dialogs.Create(title, panel, null, "Close");
        dialog.Resources["ContentDialogMaxWidth"] = 720.0;
        await context.Dialogs.ShowAsync(dialog);
    }
}
