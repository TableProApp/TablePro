using System.Globalization;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Media;
using Microsoft.Windows.Storage.Pickers;
using TablePro.App.Model;
using TablePro.App.Services;
using TablePro.Interop;

namespace TablePro.App.Views;

// Message is worded for the status bar; when TableChanged, a tab showing the table reads its rows again.
internal sealed record CsvImportResult(CsvImportReport Report, string Message)
{
    public bool Succeeded => Report.Ending == CsvImportEnding.Imported;

    public bool TableChanged => Report.TableChanged;
}

// A CSV file into a table, as the Linux app imports one: the file, its options, then a field for each column.
internal static class ImportCsvDialog
{
    private const double MappingHeight = 320;
    private const double FieldWidth = 220;
    private const double ScrollBarGutter = 16;

    private static readonly CsvDelimiter[] _delimiters =
        [CsvDelimiter.Comma, CsvDelimiter.Semicolon, CsvDelimiter.Tab, CsvDelimiter.Pipe];

    private static readonly string[] _extensions = [".csv", ".tsv", ".txt"];

    // Null when cancelled or another dialog holds the window. `importing` hears the row count as the rows go out.
    public static async Task<CsvImportResult?> RunAsync(
        FrameworkElement owner,
        DatabaseSession session,
        TableName table,
        Action<long>? importing = null,
        CancellationToken cancellationToken = default)
    {
        ArgumentNullException.ThrowIfNull(owner);
        ArgumentNullException.ThrowIfNull(session);
        ArgumentNullException.ThrowIfNull(table);
        if (WindowDialogs.IsOpen(owner.XamlRoot))
        {
            return null;
        }

        if (session.IsReadOnly)
        {
            return Ended(table, CsvImportReport.Refused(ReadOnlyRefusal));
        }

        if (await PickFileAsync(owner).ConfigureAwait(true) is not { } path)
        {
            return null;
        }

        CsvImport import;
        try
        {
            import = await session.OpenCsvImportAsync(table, cancellationToken).ConfigureAwait(true);
        }
        catch (TableProException exception)
        {
            return Ended(table, CsvImportReport.Refused(exception.Error));
        }
        catch (OperationCanceledException)
        {
            return null;
        }

        using (import)
        {
            var sheet = new Sheet(owner, import, table, path);
            if (await sheet.ShowAsync(owner).ConfigureAwait(true) is not { } planned)
            {
                return null;
            }

            var confirmed = planned.Gate == SaveGate.Run;
            if (planned.Gate == SaveGate.Confirm)
            {
                if (!await ConfirmAsync(owner, session.Name, table, planned).ConfigureAwait(true))
                {
                    return null;
                }

                confirmed = true;
            }

            importing?.Invoke(planned.Rows);
            CsvImportReport report;
            try
            {
                var outcome = await import.RunAsync(planned, confirmed, cancellationToken).ConfigureAwait(true);
                report = CsvImportReport.From(outcome);
            }
            catch (TableProException exception)
            {
                report = CsvImportReport.Refused(exception.Error);
            }
            catch (OperationCanceledException)
            {
                report = CsvImportReport.Stopped;
            }

            return Ended(table, report);
        }
    }

    private static CoreError ReadOnlyRefusal =>
        new("edit.read_only_connection", ["edit.read_only_connection"], "the connection is read-only", null, null);

    // A style keeps the dialog's own theme, which a brush read from the app's resources in code would not.
    private static Style Caption => (Style)Application.Current.Resources["CaptionTextBlockStyle"];

    private static CsvImportResult Ended(TableName table, CsvImportReport report) =>
        new(report, Describe(table, report));

    // As the Linux app words a failure: by the lines of the file the failed statement held.
    private static string Describe(TableName table, CsvImportReport report)
    {
        var error = report.Error is { } failure ? Strings.Error(failure) : null;
        var lines = report.Lines switch
        {
            null => Strings.Get("ImportCsvSomeLines"),
            { } span when span.First == span.Last => Strings.Format("ImportCsvLine", span.First),
            { } span => Strings.Format("ImportCsvLines", span.First, span.Last),
        };
        return report.Ending switch
        {
            CsvImportEnding.Imported => report.Rows == 1
                ? Strings.Format("ImportCsvDoneOne", table.Name)
                : Strings.Format("ImportCsvDoneMany", report.Rows, table.Name),
            CsvImportEnding.NotWritten when report.Lines is null =>
                Sentences(Strings.Get("ImportCsvNotWritten"), error),
            CsvImportEnding.NotWritten => Sentences(Strings.Format("ImportCsvRolledBack", lines), error),
            _ when report.Error is null => Strings.Get("ImportCsvStopped"),
            _ when report.Lines is not null => Sentences(Strings.Format("ImportCsvUnknownLines", lines), error),
            _ => Sentences(Strings.Get("ImportCsvUnknown"), error),
        };
    }

    private static string Sentences(params string?[] parts) =>
        string.Join(' ', parts.Where(part => !string.IsNullOrEmpty(part)));

    // The picker belongs to the window the workspace is in, which a tab window has its own of.
    private static async Task<string?> PickFileAsync(FrameworkElement owner)
    {
        if (owner.XamlRoot is not { } root)
        {
            return null;
        }

        var picker = new FileOpenPicker(root.ContentIslandEnvironment.AppWindowId)
        {
            SuggestedStartLocation = PickerLocationId.DocumentsLibrary,
        };
        foreach (var extension in _extensions)
        {
            picker.FileTypeFilter.Add(extension);
        }

        var result = await picker.PickSingleFileAsync();
        return result?.Path;
    }

    // Safe Mode's question before the rows are sent, with the statements that send them.
    private static async Task<bool> ConfirmAsync(
        FrameworkElement owner, string connection, TableName table, CsvImportCheck.Ready planned)
    {
        var review = CsvImportForm.Review(planned.Statements);
        var count = planned.Statements.Count;
        var content = new StackPanel { Spacing = 12 };
        content.Children.Add(Named(
            new TextBlock { Text = Strings.Format("SaveReviewRunsOn", connection), TextWrapping = TextWrapping.Wrap },
            "ImportReviewRunsOn"));
        var counted = (count, review.Shown) switch
        {
            (1, _) => Strings.Get("ImportCsvReviewOne"),
            var (all, shown) when shown == all => Strings.Format("ImportCsvReviewMany", all),
            (_, 1) => Strings.Format("ImportCsvReviewFirstShown", count),
            _ => Strings.Format("ImportCsvReviewSomeShown", count, review.Shown),
        };
        content.Children.Add(Named(
            new TextBlock { Text = counted, TextWrapping = TextWrapping.Wrap },
            "ImportReviewCount"));
        content.Children.Add(Named(
            new TextBlock
            {
                Text = review.Text,
                FontFamily = new FontFamily("Cascadia Mono, Consolas, Courier New"),
                TextWrapping = TextWrapping.Wrap,
                IsTextSelectionEnabled = true,
            },
            "ImportReviewStatements"));
        var dialog = new ContentDialog
        {
            RequestedTheme = owner.ActualTheme,
            Title = planned.Rows == 1
                ? Strings.Format("ImportCsvReviewTitleOne", table.Name)
                : Strings.Format("ImportCsvReviewTitleMany", planned.Rows, table.Name),
            Content = new ScrollViewer { Content = content, MaxHeight = 480 },
            PrimaryButtonText = Strings.Get("ImportCsvAction"),
            CloseButtonText = Strings.Get("Cancel"),
            DefaultButton = ContentDialogButton.Close,
        };
        return await WindowDialogs.ShowAsync(dialog, owner).ConfigureAwait(true) == ContentDialogResult.Primary;
    }

    private static T Named<T>(T element, string automationId, string? name = null)
        where T : UIElement
    {
        AutomationProperties.SetAutomationId(element, automationId);
        if (name is not null)
        {
            AutomationProperties.SetName(element, name);
        }

        return element;
    }

    // The mapping dialog over one import; it stays open on a file it cannot read or a row a column refuses.
    private sealed class Sheet
    {
        private readonly CsvImport _import;
        private readonly CsvImportForm _form;
        private readonly ContentDialog _dialog;
        private readonly ComboBox _delimiter = new() { MinWidth = 160 };
        private readonly CheckBox _header = new() { IsChecked = true };
        private readonly TextBox _nullText = new() { MinWidth = 200, IsSpellCheckEnabled = false };
        private readonly TextBlock _summary = new() { TextWrapping = TextWrapping.Wrap };
        private readonly InfoBar _message = new() { IsClosable = false, Severity = InfoBarSeverity.Error };
        private readonly List<(ComboBox Fields, TextBlock Note)> _rows = [];

        // The previews and the plan run on the import, which the caller disposes once the dialog is done.
        private readonly List<Task> _pending = [];
        private CsvImportCheck.Ready? _planned;
        private bool _filling;

        public Sheet(FrameworkElement owner, CsvImport import, TableName table, string path)
        {
            _import = import;
            _form = new CsvImportForm(import.Columns, path);
            _dialog = new ContentDialog
            {
                RequestedTheme = owner.ActualTheme,
                Title = Strings.Format("ImportCsvTitle", table.Name),
                Content = Layout(),
                PrimaryButtonText = Strings.Get("ImportCsvAction"),
                CloseButtonText = Strings.Get("Cancel"),
                DefaultButton = ContentDialogButton.Primary,
                IsPrimaryButtonEnabled = false,
            };
            _dialog.PrimaryButtonClick += OnImport;
        }

        // The plan when Import closed the dialog with one Safe Mode lets run, else null.
        public async Task<CsvImportCheck.Ready?> ShowAsync(FrameworkElement owner)
        {
            Read();
            var shown = await WindowDialogs.ShowAsync(_dialog, owner).ConfigureAwait(true);
            await Task.WhenAll(_pending).ConfigureAwait(true);
            return shown == ContentDialogResult.Primary ? _planned : null;
        }

        private StackPanel Layout()
        {
            var root = new StackPanel { Spacing = 12 };
            root.Children.Add(Named(
                new TextBlock
                {
                    Text = Strings.Format("ImportCsvFile", _form.FileName),
                    TextWrapping = TextWrapping.Wrap,
                },
                "ImportCsvFile"));

            _delimiter.Header = Strings.Get("ImportCsvDelimiter");
            foreach (var delimiter in _delimiters)
            {
                _delimiter.Items.Add(Strings.Get("ImportCsvDelimiter" + delimiter));
            }

            _delimiter.SelectedIndex = Array.IndexOf(_delimiters, _form.Options.Delimiter);
            Named(_delimiter, "ImportCsvDelimiter", Strings.Get("ImportCsvDelimiter"));
            _delimiter.SelectionChanged += (_, _) => Read();

            _nullText.Header = Strings.Get("ImportCsvNullText");
            _nullText.PlaceholderText = Strings.Get("ImportCsvNullTextPlaceholder");
            Named(_nullText, "ImportCsvNullText", Strings.Get("ImportCsvNullText"));
            _nullText.TextChanged += (_, _) =>
            {
                _form.SetNullText(_nullText.Text);
                Redraw();
            };

            var options = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 12 };
            options.Children.Add(_delimiter);
            options.Children.Add(_nullText);
            root.Children.Add(options);

            _header.Content = Strings.Get("ImportCsvHasHeader");
            Named(_header, "ImportCsvHasHeader", Strings.Get("ImportCsvHasHeader"));
            _header.Checked += (_, _) => Read();
            _header.Unchecked += (_, _) => Read();
            root.Children.Add(_header);

            root.Children.Add(Named(_summary, "ImportCsvSummary"));
            root.Children.Add(Named(_message, "ImportCsvMessage"));
            root.Children.Add(Named(
                new TextBlock
                {
                    Text = Strings.Get("ImportCsvColumns"),
                    Style = (Style)Application.Current.Resources["BodyStrongTextBlockStyle"],
                },
                "ImportCsvColumns"));

            var list = new StackPanel { Spacing = 12, Padding = new Thickness(0, 0, ScrollBarGutter, 0) };
            for (var column = 0; column < _form.Columns.Count; column++)
            {
                list.Children.Add(Row(column));
            }

            // A wide table scrolls here, and the options above stay in view.
            root.Children.Add(Named(
                new ScrollViewer { Content = list, MaxHeight = MappingHeight },
                "ImportCsvMapping",
                Strings.Get("ImportCsvColumns")));
            return root;
        }

        private Grid Row(int column)
        {
            var info = _form.Columns[column];
            var id = column.ToString(CultureInfo.InvariantCulture);
            var row = new Grid { ColumnSpacing = 12 };
            row.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
            row.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });

            var text = new StackPanel();
            text.Children.Add(Named(
                new TextBlock { Text = info.Name, TextTrimming = TextTrimming.CharacterEllipsis },
                "ImportCsvColumn" + id));
            text.Children.Add(Named(
                new TextBlock { Text = info.TypeName, Style = Caption, TextTrimming = TextTrimming.CharacterEllipsis },
                "ImportCsvType" + id));
            var note = Named(new TextBlock { Style = Caption, TextWrapping = TextWrapping.Wrap }, "ImportCsvNote" + id);
            text.Children.Add(note);
            row.Children.Add(text);

            var fields = Named(
                new ComboBox { Width = FieldWidth, VerticalAlignment = VerticalAlignment.Center },
                "ImportCsvField" + id,
                info.Name);
            fields.SelectionChanged += (_, _) =>
            {
                if (_filling)
                {
                    return;
                }

                _form.Choose(column, fields.SelectedIndex);
                _message.IsOpen = false;
                Redraw();
            };
            Grid.SetColumn(fields, 1);
            row.Children.Add(fields);
            _rows.Add((fields, note));
            return row;
        }

        private void Read()
        {
            var read = _form.Read(_delimiters[Math.Max(0, _delimiter.SelectedIndex)], _header.IsChecked == true);
            _message.IsOpen = false;
            Redraw();
            _pending.RemoveAll(task => task.IsCompleted);
            _pending.Add(ReadAsync(read, _form.Options));
        }

        private async Task ReadAsync(int read, CsvOptions options)
        {
            try
            {
                var preview = await _import.PreviewAsync(_form.FilePath, options).ConfigureAwait(true);
                if (_form.Show(read, preview, _import.SuggestMapping(preview.Headers)))
                {
                    Fill();
                }
            }
            catch (TableProException exception)
            {
                if (_form.Fail(read, exception.Error))
                {
                    Fill();
                }
            }
        }

        // One list for every column's box: each keeps its own selection, and a wide file is held once.
        private void Fill()
        {
            List<string> choices = [Strings.Get("ImportCsvSkip"), .. _form.Fields.Select(FieldText)];
            _filling = true;
            try
            {
                for (var column = 0; column < _rows.Count; column++)
                {
                    var fields = _rows[column].Fields;
                    fields.ItemsSource = choices;
                    fields.SelectedIndex = _form.Choice(column);
                }
            }
            finally
            {
                _filling = false;
            }

            if (_form.ReadError is { } error)
            {
                ShowMessage(Strings.Error(error));
            }

            Redraw();
        }

        private void Redraw()
        {
            var editable = !_form.IsPlanning;
            for (var column = 0; column < _rows.Count; column++)
            {
                var (fields, note) = _rows[column];
                var line = _form.Line(column);
                fields.IsEnabled = editable && !line.Column.ServerFilled;
                note.Text = NoteText(line);
            }

            _delimiter.IsEnabled = editable;
            _header.IsEnabled = editable;
            _nullText.IsEnabled = editable;
            _summary.Text = _form.IsPlanning ? Strings.Get("ImportCsvPlanning") : _form.State switch
            {
                CsvImportState.Reading => Strings.Get("ImportCsvReading"),
                CsvImportState.NoRows => Strings.Get("ImportCsvNoRows"),
                CsvImportState.NothingMapped => Strings.Get("ImportCsvNothingMapped"),
                CsvImportState.Ready when _form.Summary is { } summary => SummaryText(summary),
                _ => string.Empty,
            };
            _summary.Visibility = _summary.Text.Length > 0 ? Visibility.Visible : Visibility.Collapsed;
            _dialog.IsPrimaryButtonEnabled = _form.CanImport;
        }

        private async void OnImport(ContentDialog sender, ContentDialogButtonClickEventArgs args)
        {
            var deferral = args.GetDeferral();
            try
            {
                var planning = PlanAsync();
                _pending.Add(planning);
                args.Cancel = !await planning.ConfigureAwait(true);
            }
            finally
            {
                deferral.Complete();
            }
        }

        // Reads the whole file; true closes the dialog with the plan, anything else stays to be fixed here.
        private async Task<bool> PlanAsync()
        {
            if (!_form.CanImport)
            {
                return false;
            }

            _form.IsPlanning = true;
            _message.IsOpen = false;
            Redraw();
            try
            {
                switch (await _import.PlanAsync(_form.FilePath, _form.Options, _form.Mapping).ConfigureAwait(true))
                {
                    case CsvImportCheck.Ready { Gate: SaveGate.Refuse }:
                        ShowMessage(Strings.Get("Error_edit_read_only_connection"));
                        return false;
                    case CsvImportCheck.Ready ready:
                        _planned = ready;
                        return true;
                    case CsvImportCheck.RowRefused refused:
                        ShowMessage(FaultText(refused.Fault));
                        return false;
                    default:
                        ShowMessage(Strings.Get("ImportCsvNoRows"));
                        return false;
                }
            }
            catch (TableProException exception)
            {
                ShowMessage(Strings.Error(exception.Error));
                return false;
            }
            finally
            {
                _form.IsPlanning = false;
                Redraw();
            }
        }

        private void ShowMessage(string text)
        {
            _message.Message = text;
            AutomationProperties.SetName(_message, text);
            // Narrator reads an InfoBar when it opens, not when its text changes.
            _message.IsOpen = false;
            _message.IsOpen = true;
        }

        private static string FieldText(CsvField field)
        {
            var label = field.Header ?? Strings.Format("ImportCsvFieldNumber", field.Index + 1);
            return field.Sample is { } sample ? Strings.Format("ImportCsvFieldSample", label, sample) : label;
        }

        private static string NoteText(CsvColumnLine line) => line.Note switch
        {
            CsvColumnNote.ServerFilled => Strings.Get("ImportCsvServerFilled"),
            CsvColumnNote.UsesDefault => Strings.Get("ImportCsvUsesDefault"),
            CsvColumnNote.LeftOut => Strings.Get("ImportCsvLeftOut"),
            _ when line.Samples.Count == 0 => Strings.Get("ImportCsvNoValues"),
            _ => string.Join(" · ", line.Samples.Select(SampleText)),
        };

        private static string SampleText(CsvSample sample) => sample.Kind switch
        {
            CsvSampleKind.Null => Strings.Get("GridMenuNull"),
            CsvSampleKind.Default => Strings.Get("ImportCsvSampleDefault"),
            CsvSampleKind.Empty => Strings.Get("ImportCsvSampleEmpty"),
            _ => sample.Text,
        };

        private static string SummaryText(CsvPreviewSummary summary)
        {
            var fields = summary.Fields == 1
                ? Strings.Get("ImportCsvFieldsOne")
                : Strings.Format("ImportCsvFieldsMany", summary.Fields);
            var rows = summary.Rows == 1
                ? Strings.Get("ImportCsvRowsOne")
                : Strings.Format("ImportCsvRowsMany", summary.Rows);
            return Strings.Format(summary.Truncated ? "ImportCsvSummaryTruncated" : "ImportCsvSummary", fields, rows);
        }

        // The reason is the code a cell edit refused alike has, which the app already words.
        private static string FaultText(CsvRowFault fault)
        {
            var reason = Strings.Get("Error_" + fault.Reason.Replace('.', '_'));
            return Strings.Format(
                "ImportCsvRowFault",
                fault.Line,
                fault.Column,
                CsvImportForm.Clip(fault.Text),
                reason.Length > 0 ? reason : Strings.Get("ImportCsvRowFaultUnknown"));
        }
    }
}
