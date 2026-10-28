using System.Globalization;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using TablePro.App.Services;
using TablePro.Core.Import;

namespace TablePro.App.Views;

/// <summary>
/// Imports a SQL file, plain or gzip, as the macOS SQL import does: the error mode, the transaction and the foreign key
/// switch first, then a progress dialog whose Stop cancels and rolls back.
/// </summary>
internal static class SqlImportDialog
{
    private static readonly (string Name, SqlImportErrorHandling Value)[] Modes =
    [
        ("Stop and Rollback", SqlImportErrorHandling.StopAndRollback),
        ("Stop and Commit", SqlImportErrorHandling.StopAndCommit),
        ("Skip and Continue", SqlImportErrorHandling.SkipAndContinue),
    ];

    /// <summary>Returns true when statements ran, so the caller reloads what it shows.</summary>
    public static async Task<bool> RunAsync(WorkspaceContext context, string path)
    {
        ArgumentNullException.ThrowIfNull(context);
        var dialogs = context.Dialogs;
        var session = context.Session;
        if (session.Profile.IsReadOnly)
        {
            await dialogs.ShowErrorAsync("Read-only connection", "Safe Mode is Read-Only on this connection, so a SQL file cannot be imported.");
            return false;
        }

        var options = await AskOptionsAsync(dialogs, path, session.Profile.Name, SqlImportStatements.For(session.Profile.Engine));
        if (options is null)
        {
            return false;
        }

        using var cancellation = new CancellationTokenSource();
        var bar = new ProgressBar { Maximum = 1000, MinWidth = 420 };
        var status = new TextBlock { Text = "Starting…", Style = (Style)Application.Current.Resources["CaptionTextBlockStyle"] };
        var panel = new StackPanel { Spacing = 12 };
        panel.Children.Add(new TextBlock { Text = Path.GetFileName(path), TextTrimming = TextTrimming.CharacterEllipsis });
        panel.Children.Add(bar);
        panel.Children.Add(status);
        var progressDialog = dialogs.Create("Importing SQL", panel, null, "Stop");
        progressDialog.CloseButtonClick += (_, _) => cancellation.Cancel();
        var progress = new Progress<SqlImportProgress>(p =>
        {
            bar.Value = p.TotalBytes > 0 ? Math.Min(1000, p.BytesRead * 1000.0 / p.TotalBytes) : 0;
            status.Text = p.Skipped > 0
                ? string.Create(CultureInfo.CurrentCulture, $"{p.Executed:N0} statements run, {p.Skipped:N0} skipped")
                : string.Create(CultureInfo.CurrentCulture, $"{p.Executed:N0} statements run");
        });

        // Hide does nothing to a dialog that has not opened yet, so a quick import waits for it to open before it can close it.
        var opened = new TaskCompletionSource();
        progressDialog.Opened += (_, _) => opened.TrySetResult();
        var shown = dialogs.ShowAsync(progressDialog);
        await opened.Task;
        SqlImportResult? result = null;
        Exception? failure = null;
        try
        {
            // A channel of its own keeps the import's transaction and SET statements off every editor tab's connection.
            await using var channel = await session.Database.OpenChannelAsync(cancellation.Token);
            result = await Task.Run(() => SqlFileImporter.ImportFileAsync(channel, path, session.Dialect, session.Profile.Engine, options, progress, cancellation.Token), cancellation.Token);
        }
        catch (OperationCanceledException)
        {
            // Stop is an answer, not an error; the importer rolled back what it could.
        }
        catch (Exception ex) when (ex is SqlImportException or IOException or InvalidDataException or UnauthorizedAccessException or System.Data.Common.DbException)
        {
            failure = ex;
        }
        finally
        {
            progressDialog.Hide();
            await shown;
            context.NotifySchemaChanged();
        }

        var name = Path.GetFileName(path);
        if (failure is SqlImportException import)
        {
            var detail = import.Failure is { } statement ? $"\n\n{statement.Statement}" : string.Empty;
            var kept = options.ErrorHandling == SqlImportErrorHandling.StopAndCommit || !options.WrapInTransaction
                ? string.Create(CultureInfo.CurrentCulture, $"\n\nThe {import.Executed:N0} statements before it were kept.")
                : string.Empty;
            await dialogs.ShowErrorAsync("Import stopped", import.Message + kept + detail);
            return true;
        }

        if (failure is not null)
        {
            await dialogs.ShowErrorAsync("Import failed", failure.Message);
            return false;
        }

        if (result is null)
        {
            context.Notify($"Stopped importing {name}.");
            return true;
        }

        var summary = string.Create(CultureInfo.CurrentCulture, $"Imported {name}: {result.Executed:N0} statements in {result.Elapsed.TotalSeconds:N1} s");
        if (result.Skipped == 0)
        {
            context.Notify(summary + ".");
            return true;
        }

        var lines = result.Errors.Take(50).Select(e => string.Create(CultureInfo.CurrentCulture, $"Line {e.Line}: {e.Message}"));
        await dialogs.ShowErrorAsync(
            string.Create(CultureInfo.CurrentCulture, $"{result.Skipped:N0} statements failed"),
            summary + string.Create(CultureInfo.CurrentCulture, $", {result.Skipped:N0} skipped.\n\n") + string.Join('\n', lines));
        return true;
    }

    private static async Task<SqlImportOptions?> AskOptionsAsync(DialogService dialogs, string path, string connection, SqlImportStatements engine)
    {
        var mode = new ComboBox { Header = "On error", ItemsSource = Modes.Select(m => m.Name).ToList(), SelectedIndex = 0, MinWidth = 240 };
        var transaction = new CheckBox { Content = "Wrap in transaction (BEGIN/COMMIT)", IsChecked = engine.SupportsTransactions, IsEnabled = engine.SupportsTransactions };
        ToolTipService.SetToolTip(transaction, engine.SupportsTransactions
            ? "Runs every statement in one transaction, so a failure rolls back what the import changed. A database that commits CREATE, ALTER and DROP as they run, such as MySQL, keeps those statements and everything before them."
            : "This database runs each statement on its own.");
        var keys = new CheckBox { Content = "Disable foreign key checks", IsChecked = engine.ForeignKeysOff is not null, IsEnabled = engine.ForeignKeysOff is not null };
        ToolTipService.SetToolTip(keys, "Temporarily disable foreign key constraints during import. Useful for importing data with circular dependencies.");
        mode.SelectionChanged += (_, _) =>
        {
            // One failure aborts a PostgreSQL transaction, so skipping errors only works statement by statement.
            var skipping = Modes[Math.Max(0, mode.SelectedIndex)].Value == SqlImportErrorHandling.SkipAndContinue;
            transaction.IsEnabled = engine.SupportsTransactions && !skipping;
            if (skipping)
            {
                transaction.IsChecked = false;
            }
        };

        long size = 0;
        try
        {
            size = new FileInfo(path).Length;
        }
        catch (IOException)
        {
        }

        var panel = new StackPanel { Spacing = 12, MinWidth = 440 };
        panel.Children.Add(new TextBlock
        {
            Text = string.Create(CultureInfo.CurrentCulture, $"Runs every statement in {Path.GetFileName(path)} ({size / 1024.0:N0} KB) on {connection}."),
            TextWrapping = TextWrapping.Wrap,
        });
        panel.Children.Add(mode);
        panel.Children.Add(transaction);
        panel.Children.Add(keys);
        if (await dialogs.ShowAsync(dialogs.Create("Import SQL File", panel, "Import", "Cancel")) != ContentDialogResult.Primary)
        {
            return null;
        }

        return new SqlImportOptions(Modes[Math.Max(0, mode.SelectedIndex)].Value, transaction.IsChecked == true, keys.IsChecked == true);
    }
}
