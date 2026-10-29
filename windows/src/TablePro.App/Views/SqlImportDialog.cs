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
        (Strings.Get("Import/OnErrorStopAndRollback"), SqlImportErrorHandling.StopAndRollback),
        (Strings.Get("Import/OnErrorStopAndCommit"), SqlImportErrorHandling.StopAndCommit),
        (Strings.Get("Import/OnErrorSkipAndContinue"), SqlImportErrorHandling.SkipAndContinue),
    ];

    /// <summary>Returns true when statements ran, so the caller reloads what it shows.</summary>
    public static async Task<bool> RunAsync(WorkspaceContext context, string path)
    {
        ArgumentNullException.ThrowIfNull(context);
        var dialogs = context.Dialogs;
        var session = context.Session;
        if (session.Profile.IsReadOnly)
        {
            await dialogs.ShowErrorAsync(Strings.Get("Table/ReadOnlyConnectionTitle"), Strings.Get("Import/ReadOnlyCannotImportSql"));
            return false;
        }

        var options = await AskOptionsAsync(dialogs, path, session.Profile.Name, SqlImportStatements.For(session.Profile.Engine));
        if (options is null)
        {
            return false;
        }

        using var cancellation = new CancellationTokenSource();
        var bar = new ProgressBar { Maximum = 1000, MinWidth = 420 };
        var status = new TextBlock { Text = Strings.Get("Import/Starting"), Style = (Style)Application.Current.Resources["CaptionTextBlockStyle"] };
        var panel = new StackPanel { Spacing = 12 };
        panel.Children.Add(new TextBlock { Text = Path.GetFileName(path), TextTrimming = TextTrimming.CharacterEllipsis });
        panel.Children.Add(bar);
        panel.Children.Add(status);
        var progressDialog = dialogs.Create(Strings.Get("Import/ImportingSqlTitle"), panel, null, Strings.Get("Common/Stop"));
        progressDialog.CloseButtonClick += (_, _) => cancellation.Cancel();
        var progress = new Progress<SqlImportProgress>(p =>
        {
            bar.Value = p.TotalBytes > 0 ? Math.Min(1000, p.BytesRead * 1000.0 / p.TotalBytes) : 0;
            status.Text = p.Skipped > 0
                ? Strings.Plural("Import/StatementsRunSkipped", p.Executed, p.Skipped)
                : Strings.Plural("Import/StatementsRun", p.Executed);
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
                ? "\n\n" + Strings.Plural("Import/StatementsKept", import.Executed)
                : string.Empty;
            await dialogs.ShowErrorAsync(Strings.Get("Import/ImportStoppedTitle"), import.Message + kept + detail);
            return true;
        }

        if (failure is not null)
        {
            await dialogs.ShowErrorAsync(Strings.Get("Import/ImportFailedTitle"), failure.Message);
            return false;
        }

        if (result is null)
        {
            context.Notify(Strings.Format("Import/StoppedImporting", name));
            return true;
        }

        if (result.Skipped == 0)
        {
            context.Notify(Strings.Plural("Import/SqlImported", result.Executed, name, result.Elapsed.TotalSeconds));
            return true;
        }

        var lines = result.Errors.Take(50).Select(e => Strings.Format("Import/ErrorLine", e.Line, e.Message));
        await dialogs.ShowErrorAsync(
            Strings.Plural("Import/StatementsFailedTitle", result.Skipped),
            Strings.Plural("Import/SqlImportedSkipped", result.Executed, name, result.Elapsed.TotalSeconds, result.Skipped) + "\n\n" + string.Join('\n', lines));
        return true;
    }

    private static async Task<SqlImportOptions?> AskOptionsAsync(DialogService dialogs, string path, string connection, SqlImportStatements engine)
    {
        var mode = new ComboBox { Header = Strings.Get("Import/OnErrorHeader"), ItemsSource = Modes.Select(m => m.Name).ToList(), SelectedIndex = 0, MinWidth = 240 };
        var transaction = new CheckBox { Content = Strings.Get("Import/WrapInTransaction"), IsChecked = engine.SupportsTransactions, IsEnabled = engine.SupportsTransactions };
        ToolTipService.SetToolTip(transaction, engine.SupportsTransactions
            ? Strings.Get("Import/WrapInTransactionToolTip")
            : Strings.Get("Import/NoTransactionsToolTip"));
        var keys = new CheckBox { Content = Strings.Get("Import/DisableForeignKeyChecks"), IsChecked = engine.ForeignKeysOff is not null, IsEnabled = engine.ForeignKeysOff is not null };
        ToolTipService.SetToolTip(keys, Strings.Get("Import/DisableForeignKeyChecksToolTip"));
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
            Text = Strings.Format("Import/SqlFileSummary", Path.GetFileName(path), size / 1024.0, connection),
            TextWrapping = TextWrapping.Wrap,
        });
        panel.Children.Add(mode);
        panel.Children.Add(transaction);
        panel.Children.Add(keys);
        if (await dialogs.ShowAsync(dialogs.Create(Strings.Get("Import/ImportSqlFileTitle"), panel, Strings.Get("Common/Import"), Strings.Get("Common/Cancel"))) != ContentDialogResult.Primary)
        {
            return null;
        }

        return new SqlImportOptions(Modes[Math.Max(0, mode.SelectedIndex)].Value, transaction.IsChecked == true, keys.IsChecked == true);
    }
}
