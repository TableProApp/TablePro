using System.Globalization;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Controls;
using TablePro.App.Controls.DataGrid;
using TablePro.App.Services;
using TablePro.App.ViewModels;
using TablePro.Core.Connections;
using TablePro.Core.Generation;
using TablePro.Core.Schema;
using GridColumn = Microsoft.UI.Xaml.Controls.ColumnDefinition;

namespace TablePro.App.Views;

/// <summary>
/// Generate Rows, as on macOS: each column's generator with its options, the row count and the seed, the problems that
/// stop a run and a preview of the first rows; then the rows go in through the session's save path in batches, with
/// progress and a Stop that keeps the batches already written.
/// </summary>
public sealed class RowGeneratorDialog
{
    private readonly WorkspaceContext _context;
    private readonly RowGeneratorViewModel _model;
    private readonly ListView _columns = new() { SelectionMode = ListViewSelectionMode.Single };
    private readonly StackPanel _options = new() { Spacing = 12, Padding = new Thickness(16, 0, 8, 0) };
    private readonly NumberBox _rows = new() { Header = Strings.Get("Tools/GenRows"), Minimum = 1, Maximum = RowGenerationSettings.MaximumRowCount, SpinButtonPlacementMode = NumberBoxSpinButtonPlacementMode.Compact, Width = 160 };
    private readonly NumberBox _seed = new() { Header = Strings.Get("Tools/GenSeed"), Minimum = 0, SpinButtonPlacementMode = NumberBoxSpinButtonPlacementMode.Hidden, Width = 140 };
    private readonly InfoBar _issues = new() { Severity = InfoBarSeverity.Warning, IsClosable = false, Title = Strings.Get("Tools/GenFixIssues") };
    private readonly DataGridView _preview = new() { Height = 190 };
    private readonly TextBlock _previewNote = new() { Opacity = 0.7, TextWrapping = TextWrapping.Wrap };
    private readonly ProgressRing _loading = new() { IsActive = true, Width = 32, Height = 32 };
    private readonly Grid _body = new() { Height = 320 };
    private readonly Dictionary<string, TextBlock> _subtitles = new(StringComparer.Ordinal);
    private ContentDialog? _dialog;
    private string? _selected;
    private bool _building;

    private RowGeneratorDialog(WorkspaceContext context, DatabaseObject table)
    {
        _context = context;
        _model = new RowGeneratorViewModel(context, table);
        _model.SettingsChanged += (_, _) => Refresh();
        AutomationProperties.SetName(_columns, Strings.Get("Tools/GenColumns"));
        AutomationProperties.SetName(_preview, Strings.Get("Tools/GenPreviewName"));
    }

    /// <summary>
    /// Shows the sheet for one table and runs the insert it configures. True when rows were inserted, so the caller
    /// reloads a tab showing the table. With <paramref name="openSql"/>, Open as SQL hands the rows over as INSERT
    /// statements instead.
    /// </summary>
    public static async Task<bool> ShowAsync(WorkspaceContext context, DatabaseObject table, Action<string>? openSql = null)
    {
        ArgumentNullException.ThrowIfNull(context);
        ArgumentNullException.ThrowIfNull(table);
        if (context.Session.Profile.IsReadOnly)
        {
            await context.Dialogs.ShowErrorAsync(Strings.Get("Tools/GenReadOnlyTitle"), Strings.Get("Tools/GenReadOnlyMessage"));
            return false;
        }

        var sheet = new RowGeneratorDialog(context, table);
        var choice = await sheet.ConfigureAsync(openSql is not null);
        if (choice == ContentDialogResult.Secondary && openSql is not null)
        {
            openSql(sheet._model.InsertScript());
            return false;
        }

        return choice == ContentDialogResult.Primary && await sheet.RunAsync();
    }

    private async Task<ContentDialogResult> ConfigureAsync(bool offersScript)
    {
        var dialogs = _context.Dialogs;
        var dialog = dialogs.Create(
            Strings.Format("Tools/GenTitle", _model.Table.Name.Name),
            BuildContent(),
            Strings.Get("Tools/GenGenerate"),
            Strings.Get("Common/Cancel"),
            offersScript ? Strings.Get("Tools/GenOpenAsSql") : null);
        dialog.Resources["ContentDialogMaxWidth"] = 1040.0;
        dialog.Resources["ContentDialogMaxHeight"] = 900.0;
        dialog.IsPrimaryButtonEnabled = false;
        dialog.IsSecondaryButtonEnabled = false;
        _dialog = dialog;
        dialog.Opened += async (_, _) => await LoadAsync();
        dialog.PrimaryButtonClick += (_, args) => args.Cancel = !_model.CanGenerate;
        return await dialogs.ShowAsync(dialog);
    }

    private Grid BuildContent()
    {
        var header = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 8 };
        var shuffle = new Button { Content = new FontIcon { Glyph = "", FontSize = 14 }, VerticalAlignment = VerticalAlignment.Bottom };
        AutomationProperties.SetName(shuffle, Strings.Get("Tools/GenNewSeed"));
        ToolTipService.SetToolTip(shuffle, Strings.Get("Tools/GenNewSeedTip"));
        shuffle.Click += (_, _) => _model.ShuffleSeed();
        header.Children.Add(_rows);
        header.Children.Add(_seed);
        header.Children.Add(shuffle);
        _rows.ValueChanged += (_, args) =>
        {
            if (!_building && !double.IsNaN(args.NewValue))
            {
                _model.SetRowCount((int)Math.Clamp(args.NewValue, 0, RowGenerationSettings.MaximumRowCount + 1));
            }
        };
        _seed.ValueChanged += (_, args) =>
        {
            if (!_building && !double.IsNaN(args.NewValue))
            {
                _model.SetSeed((ulong)Math.Max(0, args.NewValue));
            }
        };

        _columns.SelectionChanged += (_, _) =>
        {
            if (_columns.SelectedItem is FrameworkElement { Tag: string name })
            {
                _selected = name;
                BuildOptions();
            }
        };

        var body = _body;
        body.ColumnDefinitions.Add(new GridColumn { Width = new GridLength(280) });
        body.ColumnDefinitions.Add(new GridColumn { Width = new GridLength(1, GridUnitType.Star) });
        body.Children.Add(new Border
        {
            Child = _columns,
            BorderThickness = new Thickness(0, 0, 1, 0),
            BorderBrush = (Microsoft.UI.Xaml.Media.Brush)Application.Current.Resources["DividerStrokeColorDefaultBrush"],
        });
        var options = new ScrollViewer { Content = _options };
        Grid.SetColumn(options, 1);
        body.Children.Add(options);

        var previewHeader = new TextBlock { Text = Strings.Get("Tools/GenPreview"), Style = (Style)Application.Current.Resources["BodyStrongTextBlockStyle"] };
        var root = new Grid { RowSpacing = 12, Width = 960 };
        for (var i = 0; i < 6; i++)
        {
            root.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });
        }

        root.Children.Add(header);
        Grid.SetRow(_loading, 1);
        root.Children.Add(_loading);
        Grid.SetRow(body, 1);
        root.Children.Add(body);
        Grid.SetRow(_issues, 2);
        root.Children.Add(_issues);
        Grid.SetRow(previewHeader, 3);
        root.Children.Add(previewHeader);
        Grid.SetRow(_preview, 4);
        root.Children.Add(_preview);
        Grid.SetRow(_previewNote, 5);
        root.Children.Add(_previewNote);
        body.Visibility = Visibility.Collapsed;
        return root;
    }

    private async Task LoadAsync()
    {
        try
        {
            await _model.LoadAsync(CancellationToken.None);
        }
        catch (Exception ex) when (ex is not OperationCanceledException)
        {
            _loading.IsActive = false;
            _loading.Visibility = Visibility.Collapsed;
            _issues.Title = Strings.Get("Tools/GenCannotReadTable");
            _issues.Message = ex.Message;
            _issues.Severity = InfoBarSeverity.Error;
            _issues.IsOpen = true;
            return;
        }

        _building = true;
        _rows.Value = _model.Settings.RowCount;
        _seed.Value = _model.Settings.Seed;
        _building = false;
        _loading.IsActive = false;
        _loading.Visibility = Visibility.Collapsed;
        _body.Visibility = Visibility.Visible;
        foreach (var column in _model.Columns)
        {
            _columns.Items.Add(ColumnItem(column));
        }

        _columns.SelectedIndex = _model.Columns.Count > 0 ? 0 : -1;
        Refresh();
    }

    private StackPanel ColumnItem(RowGenerationColumn column)
    {
        var item = new StackPanel { Tag = column.Name, Padding = new Thickness(0, 4, 0, 4) };
        item.Children.Add(new TextBlock { Text = column.Name, TextTrimming = TextTrimming.CharacterEllipsis });
        var subtitle = new TextBlock { FontSize = 12, Opacity = 0.7, TextTrimming = TextTrimming.CharacterEllipsis };
        _subtitles[column.Name] = subtitle;
        item.Children.Add(subtitle);
        AutomationProperties.SetName(item, column.Name);
        return item;
    }

    /// <summary>Everything a change can move: column subtitles, the problems, the preview and the buttons.</summary>
    private void Refresh()
    {
        if (_model.Target is null)
        {
            return;
        }

        foreach (var column in _model.Columns)
        {
            if (_subtitles.TryGetValue(column.Name, out var subtitle))
            {
                subtitle.Text = $"{column.TypeName} · {ToolsNames.GeneratorKindName(_model.SettingsFor(column.Name).Kind)}";
            }
        }

        var issues = _model.Issues;
        _issues.Severity = InfoBarSeverity.Warning;
        _issues.Title = Strings.Get("Tools/GenFixIssues");
        _issues.Message = string.Join("\n", issues.Take(6).Select(i => i.Message));
        _issues.IsOpen = issues.Count > 0;
        var (rows, problem) = _model.Preview();
        _preview.Source = rows is null ? null : new ResultGridSource(rows);
        _previewNote.Text = problem
            ?? (issues.Count > 0 ? Strings.Get("Tools/GenPreviewWaiting") : Strings.Format("Tools/GenPreviewNote", _model.Settings.RowCount));
        if (_dialog is not null)
        {
            _dialog.IsPrimaryButtonEnabled = _model.CanGenerate && problem is null;
            _dialog.IsSecondaryButtonEnabled = _model.CanOpenScript && problem is null;
        }
    }

    private void BuildOptions()
    {
        _options.Children.Clear();
        if (_selected is null || _model.Target?.Model.Column(_selected) is not { } column)
        {
            return;
        }

        var settings = _model.SettingsFor(column.Name);
        var kinds = column.AvailableKinds;
        _options.Children.Add(new TextBlock { Text = $"{column.Name}  {column.TypeName}", Style = (Style)Application.Current.Resources["BodyStrongTextBlockStyle"] });
        if (kinds.Count == 0)
        {
            _options.Children.Add(Note(Strings.Get("Tools/GenNoGenerator")));
            return;
        }

        var kind = new ComboBox { Header = Strings.Get("Tools/GenGenerator"), ItemsSource = kinds.Select(ToolsNames.GeneratorKindName).ToList(), MinWidth = 240 };
        kind.SelectedIndex = Math.Max(0, IndexOf(kinds, settings.Kind));
        kind.SelectionChanged += (_, _) =>
        {
            if (kind.SelectedIndex >= 0)
            {
                _model.SetKind(column.Name, kinds[kind.SelectedIndex]);
                _options.DispatcherQueue.TryEnqueueLogged(BuildOptions);
            }
        };
        _options.Children.Add(kind);
        AddKindOptions(column, settings);

        if (settings.Kind != RowGeneratorKind.ServerDefault && column.IsNullable && !column.IsUnique)
        {
            _options.Children.Add(Percent(Strings.Get("Tools/GenNullValues"), settings.NullRatio, value => _model.Update(column.Name, s => s with { NullRatio = value })));
        }

        foreach (var issue in _model.Issues.Where(i => i.Column == column.Name))
        {
            _options.Children.Add(new InfoBar { Severity = InfoBarSeverity.Warning, IsOpen = true, IsClosable = false, Message = issue.Message });
        }
    }

    private void AddKindOptions(RowGenerationColumn column, RowGeneratorSettings settings)
    {
        var name = column.Name;
        switch (settings.Kind)
        {
            case RowGeneratorKind.ServerDefault:
                _options.Children.Add(Note(column.Ownership == ServerOwnership.None
                    ? Strings.Get("Tools/GenServerDefaultNote")
                    : Strings.Get("Tools/GenServerFillsNote")));
                break;
            case RowGeneratorKind.Reference:
            {
                var source = column.Reference is { } slot ? _model.Target!.Model.Reference(slot.SourceId) : null;
                _options.Children.Add(Note(source is null
                    ? Strings.Get("Tools/GenReferenceNote")
                    : Strings.Plural("Tools/GenReferenceSampledNote", source.Tuples.Count, source.ReferencedTable)));
                break;
            }

            case RowGeneratorKind.Sequence:
                _options.Children.Add(Pair(
                    Number(Strings.Get("Tools/GenStart"), settings.IntegerMinimum, v => _model.Update(name, s => s with { IntegerMinimum = (long)v })),
                    Number(Strings.Get("Tools/GenStep"), settings.SequenceStep, v => _model.Update(name, s => s with { SequenceStep = (long)v }))));
                break;
            case RowGeneratorKind.IntegerRange:
                _options.Children.Add(Pair(
                    Number(Strings.Get("Tools/GenMinimum"), settings.IntegerMinimum, v => _model.Update(name, s => s with { IntegerMinimum = (long)v })),
                    Number(Strings.Get("Tools/GenMaximum"), settings.IntegerMaximum, v => _model.Update(name, s => s with { IntegerMaximum = (long)v }))));
                break;
            case RowGeneratorKind.DecimalRange:
                _options.Children.Add(Pair(
                    Number(Strings.Get("Tools/GenMinimum"), settings.DecimalMinimum, v => _model.Update(name, s => s with { DecimalMinimum = v }), decimals: true),
                    Number(Strings.Get("Tools/GenMaximum"), settings.DecimalMaximum, v => _model.Update(name, s => s with { DecimalMaximum = v }), decimals: true)));
                _options.Children.Add(Number(Strings.Get("Tools/GenDecimalPlaces"), settings.DecimalScale, v => _model.Update(name, s => s with { DecimalScale = (int)v }), maximum: RowGenerationValidation.MaximumScale));
                break;
            case RowGeneratorKind.Text:
                _options.Children.Add(Pair(
                    Number(Strings.Get("Tools/GenShortest"), settings.MinLength, v => _model.Update(name, s => s with { MinLength = (int)v })),
                    Number(Strings.Get("Tools/GenLongest"), settings.MaxLength, v => _model.Update(name, s => s with { MaxLength = (int)v }), maximum: column.MaxLength)));
                break;
            case RowGeneratorKind.Date or RowGeneratorKind.DateTime:
                _options.Children.Add(Pair(
                    Date(Strings.Get("Tools/GenDateFrom"), settings.DateStart, v => _model.Update(name, s => s with { DateStart = v })),
                    Date(Strings.Get("Tools/GenDateTo"), settings.DateEnd, v => _model.Update(name, s => s with { DateEnd = v }))));
                break;
            case RowGeneratorKind.Uuid:
            {
                var version = new ComboBox
                {
                    Header = Strings.Get("Tools/GenUuidVersion"),
                    ItemsSource = new List<string> { Strings.Get("Tools/GenUuidVersion4"), Strings.Get("Tools/GenUuidVersion7") },
                    SelectedIndex = settings.UuidVersion == UuidVersion.V7 ? 1 : 0,
                };
                version.SelectionChanged += (_, _) => _model.Update(name, s => s with { UuidVersion = version.SelectedIndex == 1 ? UuidVersion.V7 : UuidVersion.V4 });
                _options.Children.Add(version);
                break;
            }

            case RowGeneratorKind.Boolean when !column.IsUnique:
                _options.Children.Add(Percent(Strings.Get("Tools/GenTrueValues"), settings.TrueRatio, v => _model.Update(name, s => s with { TrueRatio = v })));
                break;
            case RowGeneratorKind.List:
            {
                var values = new TextBox
                {
                    Header = Strings.Get("Tools/GenListValues"),
                    Text = string.Join("\r", settings.Values),
                    AcceptsReturn = true,
                    TextWrapping = TextWrapping.Wrap,
                    Height = 120,
                };
                values.TextChanged += (_, _) => _model.Update(name, s => s with { Values = values.Text.Split('\r', '\n').Select(v => v.Trim()).ToArray() });
                _options.Children.Add(values);
                break;
            }

            case RowGeneratorKind.Pattern:
            {
                var pattern = new TextBox { Header = Strings.Get("Tools/GenPattern"), Text = settings.Pattern, Description = Strings.Get("Tools/GenPatternHelp") };
                pattern.TextChanged += (_, _) => _model.Update(name, s => s with { Pattern = pattern.Text });
                _options.Children.Add(pattern);
                break;
            }

            default:
                _options.Children.Add(Note(Strings.Format("Tools/GenVocabularyNote", ToolsNames.GeneratorKindName(settings.Kind).ToLower(CultureInfo.CurrentCulture))));
                break;
        }
    }

    private static TextBlock Note(string text) => new() { Text = text, TextWrapping = TextWrapping.Wrap, Opacity = 0.75 };

    private static StackPanel Pair(FrameworkElement first, FrameworkElement second)
    {
        var panel = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 12 };
        panel.Children.Add(first);
        panel.Children.Add(second);
        return panel;
    }

    private static NumberBox Number(string header, double value, Action<double> changed, bool decimals = false, double? maximum = null)
    {
        var box = new NumberBox
        {
            Header = header,
            Value = value,
            Width = 170,
            SpinButtonPlacementMode = NumberBoxSpinButtonPlacementMode.Compact,
            NumberFormatter = new Windows.Globalization.NumberFormatting.DecimalFormatter { FractionDigits = decimals ? 2 : 0, IsGrouped = false },
        };
        if (maximum is { } max)
        {
            box.Maximum = max;
        }

        box.ValueChanged += (_, args) =>
        {
            if (!double.IsNaN(args.NewValue))
            {
                changed(args.NewValue);
            }
        };
        return box;
    }

    private static CalendarDatePicker Date(string header, DateOnly value, Action<DateOnly> changed)
    {
        var picker = new CalendarDatePicker { Header = header, Date = new DateTimeOffset(value.ToDateTime(TimeOnly.MinValue)), Width = 170 };
        picker.DateChanged += (_, args) =>
        {
            if (args.NewDate is { } date)
            {
                changed(DateOnly.FromDateTime(date.Date));
            }
        };
        return picker;
    }

    private static Slider Percent(string header, double ratio, Action<double> changed)
    {
        var slider = new Slider { Header = header, Minimum = 0, Maximum = 100, Value = Math.Round(ratio * 100), StepFrequency = 5, Width = 260, HorizontalAlignment = HorizontalAlignment.Left };
        slider.ValueChanged += (_, args) => changed(args.NewValue / 100);
        return slider;
    }

    private static int IndexOf(IReadOnlyList<RowGeneratorKind> kinds, RowGeneratorKind kind)
    {
        for (var i = 0; i < kinds.Count; i++)
        {
            if (kinds[i] == kind)
            {
                return i;
            }
        }

        return -1;
    }

    private async Task<bool> RunAsync()
    {
        var dialogs = _context.Dialogs;
        var count = _model.Settings.RowCount;
        var name = _model.Table.Name.ToString();
        if (_context.Session.Profile.SafeMode.RequiresConfirmation()
            && !await dialogs.ConfirmAsync(Strings.Get("Tools/GenInsertConfirmTitle"), Strings.Plural("Tools/GenInsertConfirmMessage", count, name), Strings.Get("Tools/GenInsert")))
        {
            return false;
        }

        using var cancellation = new CancellationTokenSource();
        var bar = new ProgressBar { Maximum = count, MinWidth = 420 };
        var status = new TextBlock { Text = Strings.Get("Tools/Starting"), Style = (Style)Application.Current.Resources["CaptionTextBlockStyle"] };
        var panel = new StackPanel { Spacing = 12 };
        panel.Children.Add(new TextBlock { Text = name, TextTrimming = TextTrimming.CharacterEllipsis });
        panel.Children.Add(bar);
        panel.Children.Add(status);
        var progressDialog = dialogs.Create(Strings.Get("Tools/GenProgressTitle"), panel, null, Strings.Get("Common/Stop"));
        progressDialog.CloseButtonClick += (_, _) => cancellation.Cancel();
        var written = 0;
        var progress = new Progress<int>(rows =>
        {
            written = rows;
            bar.Value = rows;
            status.Text = Strings.Plural("Tools/GenProgress", count, rows);
        });

        // Hide does nothing to a dialog that has not opened yet, so a quick run waits for it to open before closing it.
        var opened = new TaskCompletionSource();
        progressDialog.Opened += (_, _) => opened.TrySetResult();
        var shown = dialogs.ShowAsync(progressDialog);
        await opened.Task;
        Exception? failure = null;
        var inserted = 0;
        try
        {
            inserted = await _model.InsertAsync(progress, cancellation.Token);
        }
        catch (OperationCanceledException)
        {
            // Stop is an answer, not an error; the batches already written stay.
        }
        catch (Exception ex) when (ex is RowGenerationWriteException or RowGenerationException)
        {
            failure = ex;
        }
        finally
        {
            progressDialog.Hide();
            await shown;
        }

        if (failure is RowGenerationWriteException write)
        {
            await dialogs.ShowErrorAsync(Strings.Get("Tools/GenStoppedTitle"), Strings.Plural("Tools/GenStoppedMessage", write.KeptRows, write.Message));
            return write.KeptRows > 0;
        }

        if (failure is not null)
        {
            await dialogs.ShowErrorAsync(Strings.Get("Tools/GenStoppedTitle"), Strings.Plural("Tools/GenStoppedMessage", written, failure.Message));
            return written > 0;
        }

        if (inserted == 0)
        {
            _context.Notify(Strings.Plural("Tools/GenStoppedAfter", written, name));
            return written > 0;
        }

        _context.Notify(Strings.Plural("Tools/GenInserted", inserted, name));
        return true;
    }
}
