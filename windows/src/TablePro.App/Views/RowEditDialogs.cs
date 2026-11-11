using System.Runtime.InteropServices;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Media;
using TablePro.App.Model;
using TablePro.App.Services;
using TablePro.Interop;
using Windows.ApplicationModel.DataTransfer;

namespace TablePro.App.Views;

// A table tab's questions about its pending changes, as macOS words them; Enter cancels all but the close question.
internal static class RowEditDialogs
{
    public static async Task<bool> ConfirmDiscardAsync(FrameworkElement owner) =>
        await ShowAsync(owner, new ContentDialog
        {
            Title = Strings.Get("DiscardChangesTitle"),
            Content = Strings.Get("DiscardChangesMessage"),
            PrimaryButtonText = Strings.Get("DiscardChangesAction"),
            CloseButtonText = Strings.Get("Cancel"),
            DefaultButton = ContentDialogButton.Close,
        }) == ContentDialogResult.Primary;

    public static async Task<bool> ConfirmReloadAsync(FrameworkElement owner, string message) =>
        await ShowAsync(owner, new ContentDialog
        {
            Title = Strings.Get("ReloadDiscardTitle"),
            Content = message,
            PrimaryButtonText = Strings.Get("ReloadDiscardAction"),
            CloseButtonText = Strings.Get("Cancel"),
            DefaultButton = ContentDialogButton.Close,
        }) == ContentDialogResult.Primary;

    // Enter saves, as macOS asks; with no Save to offer, Enter cancels.
    public static async Task<SaveBeforeClose> AskSaveBeforeCloseAsync(FrameworkElement owner, string tab, bool offerSave)
    {
        var result = await ShowAsync(owner, new ContentDialog
        {
            Title = Strings.Format("SaveBeforeCloseTab", tab),
            Content = Strings.Get("SaveBeforeCloseMessage"),
            PrimaryButtonText = offerSave ? Strings.Get("SaveBeforeCloseSave") : string.Empty,
            SecondaryButtonText = Strings.Get("SaveBeforeCloseDontSave"),
            CloseButtonText = Strings.Get("Cancel"),
            DefaultButton = offerSave ? ContentDialogButton.Primary : ContentDialogButton.Close,
        });
        return result switch
        {
            ContentDialogResult.Primary => SaveBeforeClose.Save,
            ContentDialogResult.Secondary => SaveBeforeClose.DontSave,
            _ => SaveBeforeClose.Cancel,
        };
    }

    // Asked before every save that deletes rows, at every Safe Mode level, as macOS asks.
    public static async Task<bool> ConfirmDeleteAsync(FrameworkElement owner, string table, int rows) =>
        await ShowAsync(owner, new ContentDialog
        {
            Title = rows == 1 ? Strings.Format("DeleteRowsTitleOne", table) : Strings.Format("DeleteRowsTitleMany", rows, table),
            Content = Strings.Get("DeleteRowsMessage"),
            PrimaryButtonText = Strings.Get("DeleteRowsAction"),
            CloseButtonText = Strings.Get("Cancel"),
            DefaultButton = ContentDialogButton.Close,
        }) == ContentDialogResult.Primary;

    // Safe Mode's question before a save: every statement in full with the values it binds.
    public static async Task<bool> ConfirmSaveAsync(FrameworkElement owner, string connection, IReadOnlyList<PlannedStatement> statements)
    {
        var content = new StackPanel { Spacing = 12 };
        content.Children.Add(new TextBlock
        {
            Text = Strings.Format("SaveReviewRunsOn", connection),
            TextWrapping = TextWrapping.Wrap,
        });
        content.Children.Add(StatementsBlock(statements, "SaveReviewStatements"));
        content.Children.Add(CopyAllButton(statements));
        return await ShowAsync(owner, new ContentDialog
        {
            Title = Title("SaveReviewTitle", statements.Count),
            Content = new ScrollViewer { Content = content, MaxHeight = 480 },
            PrimaryButtonText = Strings.Get("SaveReviewAction"),
            CloseButtonText = Strings.Get("Cancel"),
            DefaultButton = ContentDialogButton.Close,
        }) == ContentDialogResult.Primary;
    }

    // `error` takes the place of the statements when the edits cannot be planned.
    public static async Task ShowPreviewAsync(FrameworkElement owner, IReadOnlyList<PlannedStatement> statements, string? error)
    {
        var content = new StackPanel { Spacing = 12 };
        if (error is not null)
        {
            content.Children.Add(new TextBlock { Text = error, TextWrapping = TextWrapping.Wrap, IsTextSelectionEnabled = true });
        }
        else if (statements.Count == 0)
        {
            content.Children.Add(new TextBlock { Text = Strings.Get("PreviewSqlEmpty") });
        }
        else
        {
            content.Children.Add(StatementsBlock(statements, "PreviewSqlStatements"));
            content.Children.Add(CopyAllButton(statements));
        }

        await ShowAsync(owner, new ContentDialog
        {
            Title = error is null && statements.Count > 0 ? Title("PreviewSqlTitle", statements.Count) : Strings.Get("PreviewSqlTitle"),
            Content = new ScrollViewer { Content = content, MaxHeight = 480 },
            CloseButtonText = Strings.Get("PreviewSqlDone"),
            DefaultButton = ContentDialogButton.Close,
        });
    }

    public static async Task ShowSaveFailedAsync(FrameworkElement owner, string message, bool incomplete)
    {
        var content = new StackPanel { Spacing = 12 };
        content.Children.Add(new TextBlock { Text = message, TextWrapping = TextWrapping.Wrap, IsTextSelectionEnabled = true });
        content.Children.Add(new TextBlock
        {
            Text = Strings.Get(incomplete ? "SaveUnknownMessage" : "SaveFailedPending"),
            TextWrapping = TextWrapping.Wrap,
        });
        await ShowAsync(owner, new ContentDialog
        {
            Title = Strings.Get(incomplete ? "SaveIncompleteTitle" : "SaveFailedTitle"),
            Content = content,
            CloseButtonText = Strings.Get("PreviewSqlDone"),
            DefaultButton = ContentDialogButton.Close,
        });
    }

    // A save binds its values, so each statement is followed by the values it sends, as the Linux app shows them.
    public static string Text(IReadOnlyList<PlannedStatement> statements)
    {
        ArgumentNullException.ThrowIfNull(statements);
        return string.Join("\n\n", statements.Select(statement => statement.Values.Count == 0
            ? statement.Sql + ";"
            : $"{statement.Sql};\n-- {Strings.Format("PreviewSqlValues", string.Join(", ", statement.Values))}"));
    }

    private static string Title(string name, int statements) =>
        $"{Strings.Get(name)} ({(statements == 1 ? Strings.Get("StatementCountOne") : Strings.Format("StatementCountMany", statements))})";

    private static TextBlock StatementsBlock(IReadOnlyList<PlannedStatement> statements, string automationId)
    {
        var block = new TextBlock
        {
            Text = Text(statements),
            FontFamily = new FontFamily("Cascadia Mono, Consolas, Courier New"),
            TextWrapping = TextWrapping.Wrap,
            IsTextSelectionEnabled = true,
        };
        AutomationProperties.SetAutomationId(block, automationId);
        return block;
    }

    private static Button CopyAllButton(IReadOnlyList<PlannedStatement> statements)
    {
        var button = new Button { Content = Strings.Get("CopyAllButton") };
        AutomationProperties.SetAutomationId(button, "CopyAllStatements");
        button.Click += (_, _) =>
        {
            var package = new DataPackage();
            package.SetText(Text(statements));
            try
            {
                Clipboard.SetContent(package);
                Clipboard.Flush();
            }
            catch (COMException)
            {
                // Another program holds the clipboard open; pressing the button again copies once it lets go.
            }
        };
        return button;
    }

    private static Task<ContentDialogResult> ShowAsync(FrameworkElement owner, ContentDialog dialog)
    {
        dialog.RequestedTheme = owner.ActualTheme;
        return WindowDialogs.ShowAsync(dialog, owner);
    }
}
