using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Controls;
using TablePro.App.Model;
using TablePro.App.Services;
using TablePro.Interop;

namespace TablePro.App.Views;

// Another app's saved connections and queries, as the macOS Import from Other App sheet brings them in.
internal static class ImportFromAppDialog
{
    private const double DialogWidth = 680;

    // Null when cancelled before Import, or another dialog holds the window.
    public static async Task<ForeignImportEnding?> RunAsync(FrameworkElement owner, Workbench workbench)
    {
        ArgumentNullException.ThrowIfNull(owner);
        ArgumentNullException.ThrowIfNull(workbench);
        if (WindowDialogs.IsOpen(owner.XamlRoot))
        {
            return null;
        }

        var importer = new CoreForeignImporter(workbench.Core, ForeignAppDirs.ForCurrentUser());
        using var panel = new ImportFromAppPanel(owner, workbench, importer);
        var dialog = new ContentDialog
        {
            RequestedTheme = owner.ActualTheme,
            CloseButtonText = Strings.Get("Cancel"),
            DefaultButton = ContentDialogButton.Primary,
        };
        // ContentDialog caps its width at 548 by default, too narrow for a row and its resolution.
        dialog.Resources["ContentDialogMaxWidth"] = DialogWidth;
        AutomationProperties.SetAutomationId(dialog, "ImportFromAppDialog");

        void Show()
        {
            dialog.Title = panel.Title;
            dialog.Content = panel.Page;
            dialog.PrimaryButtonText = panel.PrimaryText;
            dialog.IsPrimaryButtonEnabled = panel.CanPrimary;
        }

        panel.Changed += (_, _) => Show();
        panel.Finished += (_, _) => dialog.Hide();
        dialog.PrimaryButtonClick += (_, args) =>
        {
            args.Cancel = true;
            panel.Primary();
        };
        // The write cannot stop halfway, so the dialog stays until it ends; a read is cancelled with it.
        dialog.Closing += (_, args) =>
        {
            if (panel.IsImporting)
            {
                args.Cancel = true;
                return;
            }

            panel.Cancel();
        };

        Show();
        panel.Start();
        await WindowDialogs.ShowAsync(dialog, owner).ConfigureAwait(true);
        panel.Cancel();
        await panel.WhenIdleAsync().ConfigureAwait(true);
        var endings = panel.Endings;
        return endings.Count > 0 ? endings[^1] : null;
    }
}
