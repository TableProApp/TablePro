using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Media;
using TablePro.App.Services;
using TablePro.Storage.Library;
using TablePro.Storage.Library.Git;

namespace TablePro.App.Views.SqlFiles;

/// <summary>
/// The commit dialog for a linked folder: its changed files with a checkbox each and a message. Only the checked
/// files are committed; whatever else is staged in the repository stays staged, as on macOS.
/// </summary>
internal static class GitCommitDialog
{
    /// <summary>Shows the dialog and commits. Returns true when a commit was made.</summary>
    public static async Task<bool> ShowAsync(DialogService dialogs, SqlLibrary library, GitCommitDraft draft, GitRepositoryInfo repository, string folderName)
    {
        if (draft.Entries.Count == 0)
        {
            await dialogs.ShowErrorAsync("Nothing to Commit", $"No file in \"{folderName}\" has changes.");
            return false;
        }

        var files = new StackPanel { Spacing = 2 };
        foreach (var entry in draft.Entries)
        {
            var label = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 8 };
            label.Children.Add(new TextBlock
            {
                Text = GitFileStatus.BadgeLetter(entry.Status.Badge),
                Width = 14,
                FontWeight = Microsoft.UI.Text.FontWeights.SemiBold,
                Foreground = (Brush)Application.Current.Resources[entry.Status.IsConflicted ? "SystemFillColorCriticalBrush" : "AccentTextFillColorPrimaryBrush"],
            });
            label.Children.Add(new TextBlock { Text = entry.FolderRelativePath, TextTrimming = TextTrimming.CharacterEllipsis });
            var box = new CheckBox { Content = label, IsChecked = draft.IsChecked(entry), IsEnabled = entry.CanCommit };
            AutomationProperties.SetName(box, entry.FolderRelativePath + ", " + entry.Status.AccessibleDescription);
            ToolTipService.SetToolTip(box, entry.CanCommit ? entry.Status.AccessibleDescription : "Resolve the conflict in a Git client before committing this file.");
            files.Children.Add(box);
        }

        var message = new TextBox { Header = "Message", AcceptsReturn = true, TextWrapping = TextWrapping.Wrap, MinHeight = 80, PlaceholderText = "Describe the change" };
        var problem = new InfoBar { Severity = InfoBarSeverity.Error, IsClosable = false, IsOpen = false };
        var output = new TextBlock { TextWrapping = TextWrapping.Wrap, IsTextSelectionEnabled = true, FontFamily = (FontFamily)Application.Current.Resources["CodeFontFamily"], FontSize = 12 };
        problem.Content = new ScrollViewer { Content = output, MaxHeight = 160 };

        var panel = new StackPanel { Spacing = 12, Width = 480 };
        panel.Children.Add(new TextBlock { Text = $"Changed files in \"{folderName}\"", Style = (Style)Application.Current.Resources["BodyStrongTextBlockStyle"] });
        panel.Children.Add(new ScrollViewer { Content = files, MaxHeight = 240 });
        panel.Children.Add(message);
        panel.Children.Add(problem);

        var dialog = dialogs.Create("Commit", panel, "Commit", "Cancel");
        void Refresh() => dialog.IsPrimaryButtonEnabled = draft.CanCommit;
        for (var i = 0; i < draft.Entries.Count; i++)
        {
            var entry = draft.Entries[i];
            var box = (CheckBox)files.Children[i];
            box.Checked += (_, _) => { draft.SetChecked(entry, true); Refresh(); };
            box.Unchecked += (_, _) => { draft.SetChecked(entry, false); Refresh(); };
        }

        message.TextChanged += (_, _) => { draft.Message = message.Text; Refresh(); };
        Refresh();

        var committed = false;
        dialog.PrimaryButtonClick += async (_, args) =>
        {
            var deferral = args.GetDeferral();
            dialog.IsPrimaryButtonEnabled = false;
            try
            {
                await library.CommitAsync(draft, repository);
                committed = true;
            }
            catch (Exception ex) when (ex is GitCommandException or GitProcessException or GitUnavailableException or InvalidOperationException)
            {
                problem.Title = "Couldn't commit";
                problem.Message = GitErrorText.Describe(ex);
                output.Text = GitErrorText.Output(ex) ?? string.Empty;
                problem.IsOpen = true;
                args.Cancel = true;
                Refresh();
            }
            finally
            {
                deferral.Complete();
            }
        };

        await dialogs.ShowAsync(dialog);
        return committed;
    }
}
