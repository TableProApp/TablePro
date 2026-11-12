using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Controls;
using Microsoft.Windows.Storage.Pickers;
using TablePro.App.Model;
using TablePro.App.Services;
using TablePro.Interop;

namespace TablePro.App.Views;

internal sealed record ExportRequest(ExportFormat Format, ExportScope Scope, string Path);

// The format and the rows asked in a dialog, then the file in the system's save picker; the core writes it.
internal static class ExportDialog
{
    // Null when either is cancelled, or another dialog holds the window.
    public static async Task<ExportRequest?> AskAsync(FrameworkElement owner, ExportPlan plan)
    {
        var formats = Choices("ExportFormatHeader", "ExportFormats", plan.Formats.Select(FormatName));
        var content = new StackPanel { Spacing = 16 };
        content.Children.Add(formats);
        // A query result has only the rows it holds; a table offers its page or all of it.
        RadioButtons? scopes = null;
        if (plan.Scopes.Count > 1)
        {
            var names = plan.Scopes.Select(scope => Strings.Get("ExportScope_" + scope));
            scopes = Choices("ExportScopeHeader", "ExportScopes", names);
            content.Children.Add(scopes);
        }

        var dialog = new ContentDialog
        {
            RequestedTheme = owner.ActualTheme,
            Title = Strings.Get("ExportTitle"),
            Content = new ScrollViewer { Content = content, MaxHeight = 480 },
            PrimaryButtonText = Strings.Get("ExportAction"),
            CloseButtonText = Strings.Get("Cancel"),
            DefaultButton = ContentDialogButton.Primary,
        };
        if (await WindowDialogs.ShowAsync(dialog, owner).ConfigureAwait(true) != ContentDialogResult.Primary)
        {
            return null;
        }

        var format = plan.Formats[Math.Max(0, formats.SelectedIndex)];
        var scopeAt = scopes is null ? 0 : Math.Max(0, scopes.SelectedIndex);
        var path = await PickFileAsync(owner, plan.FileName, format).ConfigureAwait(true);
        return path is null ? null : new ExportRequest(format, plan.Scopes[scopeAt], path);
    }

    public static string FormatName(ExportFormat format) => Strings.Get("ExportFormat_" + format);

    private static RadioButtons Choices(string header, string automationId, IEnumerable<string> names)
    {
        var choices = new RadioButtons { Header = Strings.Get(header) };
        foreach (var name in names)
        {
            choices.Items.Add(name);
        }

        choices.SelectedIndex = 0;
        AutomationProperties.SetName(choices, Strings.Get(header));
        AutomationProperties.SetAutomationId(choices, automationId);
        return choices;
    }

    // The picker belongs to the window the workspace is in, which a tab window has its own of.
    private static async Task<string?> PickFileAsync(FrameworkElement owner, string fileName, ExportFormat format)
    {
        if (owner.XamlRoot is not { } root)
        {
            return null;
        }

        var picker = new FileSavePicker(root.ContentIslandEnvironment.AppWindowId)
        {
            SuggestedStartLocation = PickerLocationId.DocumentsLibrary,
            SuggestedFileName = fileName,
        };
        picker.FileTypeChoices.Add(FormatName(format), [ExportPlan.Extension(format)]);
        var result = await picker.PickSaveFileAsync();
        return result?.Path;
    }
}
