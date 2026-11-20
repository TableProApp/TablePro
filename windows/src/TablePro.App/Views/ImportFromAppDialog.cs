using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Controls;
using Microsoft.Windows.Storage.Pickers;
using TablePro.App.Model;
using TablePro.App.Services;
using TablePro.Interop;

namespace TablePro.App.Views;

// Another app's saved connections and queries, as the macOS Import from Other App sheet brings them in.
internal static class ImportFromAppDialog
{
    private const double DialogWidth = 680;
    private const double ConnectionsHeight = 320;
    private const double QueriesHeight = 180;
    private const double ResolutionWidth = 220;
    private const double NoteIndent = 28;

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
        using var sheet = new Sheet(owner, workbench, importer);
        return await sheet.ShowAsync().ConfigureAwait(true);
    }

    public static string Describe(ForeignImportEnding ending)
    {
        ArgumentNullException.ThrowIfNull(ending);
        return Strings.Sentences([.. ending.Sentences.Select(sentence => Sentence(sentence, ending.Error))]);
    }

    public static InfoBarSeverity Severity(ForeignImportEnding ending)
    {
        ArgumentNullException.ThrowIfNull(ending);
        return ending switch
        {
            { Outdated: true } or { Partial: true } => InfoBarSeverity.Warning,
            { Error: not null } => InfoBarSeverity.Error,
            { Nothing: true } => InfoBarSeverity.Informational,
            _ => InfoBarSeverity.Success,
        };
    }

    private static string Sentence(ForeignImportSentence sentence, CoreError? error) => sentence.Part switch
    {
        ForeignImportPart.Nothing => Strings.Get("ImportAppDone_Nothing"),
        ForeignImportPart.Outdated => Strings.Get("ImportAppDone_Outdated"),
        ForeignImportPart.Failed when error is not null =>
            Strings.Sentences(Strings.Get("ImportAppDone_Failed"), Strings.Error(error)),
        ForeignImportPart.Failed => Strings.Get("ImportAppDone_Failed"),
        _ => Strings.Plural("ImportAppDone_" + sentence.Part, sentence.Count, sentence.Count),
    };

    // A style keeps the dialog's own theme, which a brush read from the app's resources in code would not.
    private static Style Caption => (Style)Application.Current.Resources["CaptionTextBlockStyle"];

    private static Style Strong => (Style)Application.Current.Resources["BodyStrongTextBlockStyle"];

    private static TextBlock Secondary(string text, double indent = 0) => new()
    {
        Text = text,
        Style = Caption,
        TextWrapping = TextWrapping.Wrap,
        Margin = new Thickness(indent, 0, 0, 0),
        Visibility = text.Length > 0 ? Visibility.Visible : Visibility.Collapsed,
    };

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

    private static string SourceText(ForeignSource source)
    {
        switch (ForeignImportForm.NoteFor(source))
        {
            case ForeignSourceNote.PicksFile:
                return Strings.Get("ImportAppSourceFile");
            case ForeignSourceNote.NotFound:
                return Strings.Get("ImportAppSourceNotFound");
        }

        var connections = Strings.Plural("ImportAppSourceConnections", source.Connections, source.Connections);
        if (source.SavedQueries == 0)
        {
            return connections;
        }

        var queries = Strings.Plural("ImportAppSourceQueries", source.SavedQueries, source.SavedQueries);
        return Strings.Format("JoinDot", connections, queries);
    }

    private static string ResolutionText(ForeignResolution resolution) => resolution switch
    {
        ForeignResolution.AddCopy => Strings.Get("ImportAppResolution_AddCopy"),
        ForeignResolution.Replace => Strings.Get("ImportAppResolution_Replace"),
        ForeignResolution.KeepExisting => Strings.Get("ImportAppResolution_KeepExisting"),
        _ => Strings.Get("ImportAppResolution_Add"),
    };

    private static string NoteText(ForeignRowNote note) => note switch
    {
        ForeignRowNote.UnsupportedEngine unsupported =>
            Strings.Format("ImportAppNote_UnsupportedEngine", unsupported.Engine),
        ForeignRowNote.SshKeyMissing missing => Strings.Format("ImportAppNote_SshKeyMissing", missing.Path),
        ForeignRowNote.JumpHostKeyMissing missing => Strings.Format("ImportAppNote_JumpHostKeyMissing", missing.Path),
        ForeignRowNote.CaCertificateMissing missing =>
            Strings.Format("ImportAppNote_CaCertificateMissing", missing.Path),
        ForeignRowNote.ClientCertificateMissing missing =>
            Strings.Format("ImportAppNote_ClientCertificateMissing", missing.Path),
        ForeignRowNote.ClientKeyMissing missing => Strings.Format("ImportAppNote_ClientKeyMissing", missing.Path),
        ForeignRowNote.TlsModeChanged changed => Strings.Format(
            "ImportAppNote_TlsModeChanged",
            SslName(changed.From),
            Strings.Get("TlsMode_" + changed.To)),
        ForeignRowNote.TlsSettingsNotRead => Strings.Get("ImportAppNote_TlsSettingsNotRead"),
        ForeignRowNote.TlsFromDriverDefault from =>
            Strings.Format("ImportAppNote_TlsFromDriverDefault", SslName(from.Mode)),
        ForeignRowNote.TlsNotKept dropped => Strings.Format("ImportAppNote_TlsNotKept", SslName(dropped.From)),
        ForeignRowNote.CaFileNotKept dropped =>
            Strings.Format("ImportAppNote_CaFileNotKept", dropped.Path, ReasonText(dropped.Reason)),
        ForeignRowNote.ClientIdentityNotKept dropped =>
            Strings.Format("ImportAppNote_ClientIdentityNotKept", ReasonText(dropped.Reason)),
        ForeignRowNote.SshNotKept => Strings.Get("ImportAppNote_SshNotKept"),
        ForeignRowNote.SshKeyNotKept dropped => Strings.Format("ImportAppNote_SshKeyNotKept", dropped.Path),
        ForeignRowNote.JumpHostNotKept dropped => Strings.Format("ImportAppNote_JumpHostNotKept", dropped.Host),
        ForeignRowNote.JumpHostPasswordNotKept dropped =>
            Strings.Format("ImportAppNote_JumpHostPasswordNotKept", dropped.Host),
        ForeignRowNote.JumpHostKeyNotKept dropped =>
            Strings.Format("ImportAppNote_JumpHostKeyNotKept", dropped.Host, dropped.Path),
        ForeignRowNote.FieldsNotKept dropped =>
            Strings.Format("ImportAppNote_FieldsNotKept", Strings.List(dropped.Fields)),
        _ => string.Empty,
    };

    private static string SslName(ForeignSslMode mode) => Strings.Get("ImportAppSsl_" + mode);

    private static string ReasonText(TlsFileReason reason) => Strings.Get("ImportAppFileReason_" + reason);

    private static string QueryText(ForeignQueryLine line) => line.Availability switch
    {
        null or ForeignQueryAvailability.Available => line.Row.ConnectionName is { } connection
            ? Strings.Format("ImportAppQueryOn", connection)
            : string.Empty,
        { } availability => Strings.Get("ImportAppQuery_" + availability),
    };

    private static string SummaryText(ForeignImportSummary summary)
    {
        var connections = Strings.Plural(
            "ImportAppSummaryConnections", summary.Connections, summary.SelectedConnections, summary.Connections);
        if (summary.Queries == 0)
        {
            return connections;
        }

        var queries = Strings.Plural("ImportAppSummaryQueries", summary.Queries, summary.IncludedQueries, summary.Queries);
        return $"{connections}\n{queries}";
    }

    // Offered is what the box lists, which a Replace another row takes changes.
    private sealed class ConnectionRow(string reference, CheckBox check, ComboBox? resolution)
    {
        public string Reference => reference;

        public CheckBox Check => check;

        public ComboBox? Resolution => resolution;

        public IReadOnlyList<ForeignResolution> Offered { get; set; } = [];
    }

    private sealed record QueryRow(string Reference, CheckBox Check, TextBlock Note);

    // One dialog from the app to the review; each step stays in it, and Import closes it once the write is done.
    private sealed class Sheet : IDisposable
    {
        private readonly FrameworkElement _owner;
        private readonly Workbench _workbench;
        private readonly ForeignImportForm _form;
        private readonly ContentDialog _dialog;
        private readonly CancellationTokenSource _closed = new();

        // The reads and the import run on the form, which is disposed once they end.
        private readonly List<Task> _pending = [];

        private readonly StackPanel _choosePage = new() { Spacing = 16 };
        private readonly StackPanel _looking = new() { Orientation = Orientation.Horizontal, Spacing = 12 };
        private readonly RadioButtons _sources = new();
        private readonly CheckBox _passwords = new();
        private readonly TextBlock _passwordsNote = Secondary(string.Empty, NoteIndent);
        private readonly CheckBox _queries = new();
        private readonly TextBlock _queriesNote = Secondary(string.Empty, NoteIndent);
        private readonly InfoBar _failure = new() { IsClosable = false, Severity = InfoBarSeverity.Error };

        private readonly StackPanel _readingPage = new() { Orientation = Orientation.Horizontal, Spacing = 12 };
        private readonly TextBlock _readingText = new() { TextWrapping = TextWrapping.Wrap };

        private readonly StackPanel _reviewPage = new() { Spacing = 12 };
        private readonly InfoBar _passwordNotice = new() { IsClosable = false, Severity = InfoBarSeverity.Warning };
        private readonly ListView _connectionList = new() { SelectionMode = ListViewSelectionMode.None };
        private readonly TextBlock _queriesHeader = new() { Style = Strong };
        private readonly ListView _queryList = new() { SelectionMode = ListViewSelectionMode.None };
        private readonly TextBlock _summary = new() { TextWrapping = TextWrapping.Wrap };
        private readonly List<ConnectionRow> _connectionRows = [];
        private readonly List<QueryRow> _queryRows = [];

        private ForeignImportEnding? _ending;
        private bool _picking;

        // Set while the boxes are set from the form, whose events then are not the user's.
        private bool _filling;

        public Sheet(FrameworkElement owner, Workbench workbench, IForeignImporter importer)
        {
            _owner = owner;
            _workbench = workbench;
            _form = new ForeignImportForm(importer, workbench.ActiveProject);
            LayOutChoose();
            LayOutReading();
            LayOutReview();
            _dialog = new ContentDialog
            {
                RequestedTheme = owner.ActualTheme,
                Title = Strings.Get("ImportAppTitle"),
                Content = _choosePage,
                PrimaryButtonText = Strings.Get("ImportAppContinue"),
                CloseButtonText = Strings.Get("Cancel"),
                DefaultButton = ContentDialogButton.Primary,
                IsPrimaryButtonEnabled = false,
            };
            // ContentDialog caps its width at 548 by default, too narrow for a row and its resolution.
            _dialog.Resources["ContentDialogMaxWidth"] = DialogWidth;
            AutomationProperties.SetAutomationId(_dialog, "ImportFromAppDialog");
            _dialog.PrimaryButtonClick += OnPrimary;
            _dialog.Closing += OnClosing;
        }

        // The ending once Import ran, refused or not, else null.
        public async Task<ForeignImportEnding?> ShowAsync()
        {
            Track(LoadAsync());
            await WindowDialogs.ShowAsync(_dialog, _owner).ConfigureAwait(true);
            await _closed.CancelAsync().ConfigureAwait(true);
            await Task.WhenAll(_pending).ConfigureAwait(true);
            return _ending;
        }

        public void Dispose()
        {
            _form.Dispose();
            _closed.Dispose();
        }

        private void LayOutChoose()
        {
            _looking.Children.Add(new ProgressRing { IsActive = true, Width = 20, Height = 20 });
            _looking.Children.Add(new TextBlock
            {
                Text = Strings.Get("ImportAppLooking"),
                VerticalAlignment = VerticalAlignment.Center,
            });
            _choosePage.Children.Add(_looking);

            _sources.Header = Strings.Get("ImportAppSourcesHeader");
            Named(_sources, "ImportAppSources", Strings.Get("ImportAppSourcesHeader"));
            _sources.SelectionChanged += (_, _) => OnSourceChosen();
            _choosePage.Children.Add(_sources);

            _choosePage.Children.Add(Option(_passwords, _passwordsNote, "ImportAppPasswords"));
            _passwords.Checked += (_, _) => OnOption();
            _passwords.Unchecked += (_, _) => OnOption();
            _choosePage.Children.Add(Option(_queries, _queriesNote, "ImportAppQueries"));
            _queries.Checked += (_, _) => OnOption();
            _queries.Unchecked += (_, _) => OnOption();

            _choosePage.Children.Add(Named(_failure, "ImportAppFailure"));
        }

        private static StackPanel Option(CheckBox box, TextBlock note, string name)
        {
            box.Content = Strings.Get(name);
            Named(box, name, Strings.Get(name));
            var panel = new StackPanel { Spacing = 2 };
            panel.Children.Add(box);
            panel.Children.Add(Named(note, name + "Note"));
            return panel;
        }

        private void LayOutReading()
        {
            _readingPage.Children.Add(new ProgressRing { IsActive = true, Width = 20, Height = 20 });
            _readingText.VerticalAlignment = VerticalAlignment.Center;
            _readingPage.Children.Add(Named(_readingText, "ImportAppReading"));
        }

        private void LayOutReview()
        {
            _reviewPage.Children.Add(Named(_passwordNotice, "ImportAppPasswordNotice"));
            var connections = Strings.Get("ImportAppConnectionsHeader");
            _reviewPage.Children.Add(new TextBlock { Text = connections, Style = Strong });
            _connectionList.MaxHeight = ConnectionsHeight;
            _reviewPage.Children.Add(Named(_connectionList, "ImportAppConnections", connections));
            _queriesHeader.Text = Strings.Get("ImportAppQueriesHeader");
            _reviewPage.Children.Add(_queriesHeader);
            _queryList.MaxHeight = QueriesHeight;
            _reviewPage.Children.Add(Named(_queryList, "ImportAppQueryList", Strings.Get("ImportAppQueriesHeader")));
            _reviewPage.Children.Add(Named(_summary, "ImportAppSummary"));
        }

        private void Track(Task task)
        {
            _pending.RemoveAll(each => each.IsCompleted);
            _pending.Add(task);
        }

        private async Task LoadAsync()
        {
            Show();
            await _form.LoadAsync().ConfigureAwait(true);
            FillSources();
            Show();
        }

        private void FillSources()
        {
            _filling = true;
            try
            {
                foreach (var source in _form.Sources)
                {
                    var subtitle = SourceText(source);
                    var content = new StackPanel();
                    content.Children.Add(new TextBlock { Text = source.Name });
                    content.Children.Add(Secondary(subtitle));
                    var button = Named(
                        new RadioButton { Content = content, IsEnabled = source.IsAvailable, Tag = source.App },
                        "ImportAppSource_" + source.App,
                        source.Name);
                    AutomationProperties.SetHelpText(button, subtitle);
                    _sources.Items.Add(button);
                }

                _sources.SelectedIndex = _form.Chosen is { } chosen
                    ? _form.Sources.ToList().FindIndex(source => source.App == chosen.App)
                    : -1;
            }
            finally
            {
                _filling = false;
            }
        }

        private void OnSourceChosen()
        {
            if (_filling || _sources.SelectedItem is not RadioButton { Tag: ForeignApp app })
            {
                return;
            }

            _form.Choose(app);
            Show();
        }

        private void OnOption()
        {
            if (_filling)
            {
                return;
            }

            _form.SetPasswords(_passwords.IsChecked == true);
            _form.SetQueries(_queries.IsChecked == true);
        }

        private void Show()
        {
            switch (_form.Step)
            {
                case ForeignImportStep.Loading:
                case ForeignImportStep.Choosing:
                    ShowChoose();
                    break;
                case ForeignImportStep.Reading:
                    _dialog.Content = _readingPage;
                    _dialog.PrimaryButtonText = string.Empty;
                    _readingText.Text = Strings.Format("ImportAppReading", AppName);
                    break;
                default:
                    _dialog.Title = Strings.Format("ImportAppReviewTitle", AppName);
                    _dialog.Content = _reviewPage;
                    _dialog.PrimaryButtonText = Strings.Get("ImportAppAction");
                    RefreshReview();
                    break;
            }
        }

        private string AppName => _form.Chosen?.Name ?? string.Empty;

        private void ShowChoose()
        {
            var loading = _form.Step == ForeignImportStep.Loading;
            _dialog.Title = Strings.Get("ImportAppTitle");
            _dialog.Content = _choosePage;
            _dialog.PrimaryButtonText = Strings.Get("ImportAppContinue");
            _dialog.IsPrimaryButtonEnabled = _form.CanContinue && !_picking;
            _looking.Visibility = loading ? Visibility.Visible : Visibility.Collapsed;
            _sources.Visibility = loading || _form.Sources.Count == 0 ? Visibility.Collapsed : Visibility.Visible;

            var passwords = _form.Passwords;
            var queries = _form.Queries;
            _filling = true;
            try
            {
                _passwords.IsEnabled = passwords.Offered;
                _passwords.IsChecked = passwords.Checked;
                _queries.IsEnabled = queries.Offered;
                _queries.IsChecked = queries.Checked;
            }
            finally
            {
                _filling = false;
            }

            _passwordsNote.Text = _form.Chosen is null
                ? string.Empty
                : Strings.Format("ImportAppPasswords_" + passwords.Note, AppName);
            _queriesNote.Text = _form.Chosen is null
                ? string.Empty
                : Strings.Format("ImportAppQueries_" + queries.Support, AppName);
            _passwordsNote.Visibility = _passwordsNote.Text.Length > 0 ? Visibility.Visible : Visibility.Collapsed;
            _queriesNote.Visibility = _queriesNote.Text.Length > 0 ? Visibility.Visible : Visibility.Collapsed;
            AutomationProperties.SetHelpText(_passwords, _passwordsNote.Text);
            AutomationProperties.SetHelpText(_queries, _queriesNote.Text);

            var failure = _form.Failure is { } read ? FailureText(read)
                : _form.SourcesError is not null ? Strings.Get("ImportAppSourcesFailed")
                : null;
            ShowMessage(_failure, failure);
        }

        private string FailureText(ForeignReadFailure failure) => failure.Kind switch
        {
            ForeignReadFailureKind.Library or ForeignReadFailureKind.Other =>
                Strings.Get("ImportAppRead_" + failure.Kind),
            _ => Strings.Format(
                "ImportAppRead_" + failure.Kind,
                _form.Sources.FirstOrDefault(source => source.App == failure.App)?.Name ?? AppName),
        };

        private static void ShowMessage(InfoBar bar, string? text)
        {
            if (text is null)
            {
                bar.IsOpen = false;
                return;
            }

            if (bar.IsOpen && bar.Message == text)
            {
                return;
            }

            bar.Message = text;
            AutomationProperties.SetName(bar, text);
            // Narrator reads an InfoBar when it opens, not when its text changes.
            bar.IsOpen = false;
            bar.IsOpen = true;
        }

        private void OnPrimary(ContentDialog sender, ContentDialogButtonClickEventArgs args)
        {
            args.Cancel = true;
            switch (_form.Step)
            {
                case ForeignImportStep.Choosing:
                    Track(ContinueAsync());
                    break;
                case ForeignImportStep.Reviewing:
                    Track(ImportAsync());
                    break;
            }
        }

        // The write cannot stop halfway, so the dialog stays until it ends; a read is cancelled with it.
        private void OnClosing(ContentDialog sender, ContentDialogClosingEventArgs args)
        {
            if (_form.Step == ForeignImportStep.Importing)
            {
                args.Cancel = true;
                return;
            }

            _closed.Cancel();
        }

        private async Task ContinueAsync()
        {
            if (_picking || !_form.CanContinue || _form.Chosen is not { } source)
            {
                return;
            }

            string? file = null;
            if (source.PicksFile)
            {
                _picking = true;
                _dialog.IsPrimaryButtonEnabled = false;
                try
                {
                    file = await PickFileAsync(source).ConfigureAwait(true);
                }
                finally
                {
                    _picking = false;
                }

                if (file is null || _closed.IsCancellationRequested)
                {
                    Show();
                    return;
                }
            }

            var reading = _form.ReadAsync(file, _closed.Token);
            Show();
            if (await reading.ConfigureAwait(true))
            {
                BuildReview();
            }

            if (!_closed.IsCancellationRequested)
            {
                Show();
            }
        }

        // The picker belongs to the window the dialog is in.
        private async Task<string?> PickFileAsync(ForeignSource source)
        {
            if (_owner.XamlRoot is not { } root)
            {
                return null;
            }

            var picker = new FileOpenPicker(root.ContentIslandEnvironment.AppWindowId)
            {
                SuggestedStartLocation = PickerLocationId.DocumentsLibrary,
            };
            foreach (var extension in source.FileExtensions)
            {
                picker.FileTypeFilter.Add("." + extension.TrimStart('.'));
            }

            var result = await picker.PickSingleFileAsync();
            return result?.Path;
        }

        private async Task ImportAsync()
        {
            if (!_form.CanImport)
            {
                return;
            }

            var importing = _form.ImportAsync();
            _dialog.IsPrimaryButtonEnabled = false;
            _connectionList.IsEnabled = false;
            _queryList.IsEnabled = false;
            _summary.Text = Strings.Get("ImportAppImporting");
            _ending = await importing.ConfigureAwait(true);
            _dialog.Hide();
        }

        private void BuildReview()
        {
            _connectionList.Items.Clear();
            _connectionRows.Clear();
            _queryList.Items.Clear();
            _queryRows.Clear();
            foreach (var line in _form.Connections)
            {
                _connectionList.Items.Add(ConnectionItem(line));
            }

            foreach (var line in _form.SavedQueries)
            {
                _queryList.Items.Add(QueryItem(line));
            }

            var queries = _form.SavedQueries.Count > 0 ? Visibility.Visible : Visibility.Collapsed;
            _queriesHeader.Visibility = queries;
            _queryList.Visibility = queries;
            ShowMessage(_passwordNotice, _form.PasswordOutcome switch
            {
                ForeignPasswordOutcome.LeftBehind => Strings.Format("ImportAppPasswordsLeftBehind", AppName),
                ForeignPasswordOutcome.Stopped => Strings.Get("ImportAppPasswordsStopped"),
                _ => null,
            });
        }

        private ListViewItem ConnectionItem(ForeignConnectionLine line)
        {
            var lines = ConnectionLines(line.Row);
            var text = new StackPanel();
            text.Children.Add(new TextBlock { Text = line.Row.Name, TextTrimming = TextTrimming.CharacterEllipsis });
            text.Children.Add(Secondary(string.Join('\n', lines)));
            var check = Named(
                new CheckBox
                {
                    Content = text,
                    IsEnabled = line.Selectable,
                    HorizontalAlignment = HorizontalAlignment.Stretch,
                },
                "ImportAppRow_" + line.Reference,
                line.Row.Name);
            AutomationProperties.SetHelpText(check, Strings.List(lines));

            var grid = new Grid { ColumnSpacing = 12, Padding = new Thickness(0, 4, 0, 4) };
            grid.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
            grid.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
            grid.Children.Add(check);

            ComboBox? resolution = null;
            if (line.Row.Duplicate is not null)
            {
                resolution = Named(
                    new ComboBox { Width = ResolutionWidth, VerticalAlignment = VerticalAlignment.Top },
                    "ImportAppResolution_" + line.Reference,
                    Strings.Get("ImportAppResolution"));
                ToolTipService.SetToolTip(resolution, Strings.Get("ImportAppResolution"));
                Grid.SetColumn(resolution, 1);
                grid.Children.Add(resolution);
            }

            var row = new ConnectionRow(line.Reference, check, resolution);
            check.Checked += (_, _) => OnSelected(row, true);
            check.Unchecked += (_, _) => OnSelected(row, false);
            if (resolution is not null)
            {
                resolution.SelectionChanged += (_, _) => OnResolved(row);
            }

            _connectionRows.Add(row);
            return Item(grid, line.Row.Name);
        }

        private ListViewItem QueryItem(ForeignQueryLine line)
        {
            var note = Secondary(QueryText(line));
            var text = new StackPanel();
            text.Children.Add(new TextBlock { Text = line.Row.Name, TextTrimming = TextTrimming.CharacterEllipsis });
            text.Children.Add(note);
            var check = Named(
                new CheckBox { Content = text, HorizontalAlignment = HorizontalAlignment.Stretch },
                "ImportAppQuery_" + line.Reference,
                line.Row.Name);
            var row = new QueryRow(line.Reference, check, note);
            check.Checked += (_, _) => OnIncluded(row, true);
            check.Unchecked += (_, _) => OnIncluded(row, false);
            _queryRows.Add(row);
            return Item(check, line.Row.Name);
        }

        private static ListViewItem Item(UIElement content, string name)
        {
            var item = new ListViewItem
            {
                Content = content,
                HorizontalContentAlignment = HorizontalAlignment.Stretch,
            };
            AutomationProperties.SetName(item, name);
            return item;
        }

        // Where it connects, where it lands, what it matches and what it loses, a line each.
        private List<string> ConnectionLines(ForeignConnectionRow row)
        {
            List<string> lines = [row.Connection is { } saved ? Describe(saved) : row.Engine];
            if (row.GroupPath.Count > 0)
            {
                lines.Add(string.Join(" / ", row.GroupPath));
            }

            if (row.Duplicate is { } existing)
            {
                lines.Add(Strings.Format("ImportAppMatches", existing.Name));
            }

            lines.AddRange(row.Notes.Select(NoteText).Where(note => note.Length > 0));
            return lines;
        }

        // As the Connections page words a connection.
        private string Describe(SavedConnection saved)
        {
            var engine = _workbench.EngineName(saved.EngineId);
            return Strings.Format(
                "ConnectionDescription", engine, ConnectionSearch.Describe(saved, _workbench.IsFileEngine(saved.EngineId)));
        }

        private void OnSelected(ConnectionRow row, bool selected)
        {
            if (_filling)
            {
                return;
            }

            _form.SetSelected(row.Reference, selected);
            RefreshReview();
        }

        private void OnResolved(ConnectionRow row)
        {
            if (_filling || row.Resolution is not { SelectedIndex: >= 0 } box || box.SelectedIndex >= row.Offered.Count)
            {
                return;
            }

            _form.Resolve(row.Reference, row.Offered[box.SelectedIndex]);
            RefreshReview();
        }

        // Even an unchanged answer is drawn again, so a box always shows what the import takes.
        private void OnIncluded(QueryRow row, bool included)
        {
            if (_filling)
            {
                return;
            }

            _form.SetIncluded(row.Reference, included);
            RefreshReview();
        }

        // A change can move another row: a Replace one row takes leaves the others, and a query follows its connection.
        private void RefreshReview()
        {
            _filling = true;
            try
            {
                foreach (var (row, line) in _connectionRows.Zip(_form.Connections))
                {
                    if (row.Check.IsChecked != line.Selected)
                    {
                        row.Check.IsChecked = line.Selected;
                    }

                    if (row.Resolution is { } box)
                    {
                        Resolutions(row, box, line);
                    }
                }

                foreach (var (row, line) in _queryRows.Zip(_form.SavedQueries))
                {
                    if (row.Check.IsChecked != line.Included)
                    {
                        row.Check.IsChecked = line.Included;
                    }

                    row.Check.IsEnabled = line.Importable;
                    row.Note.Text = QueryText(line);
                    row.Note.Visibility = row.Note.Text.Length > 0 ? Visibility.Visible : Visibility.Collapsed;
                    AutomationProperties.SetHelpText(row.Check, row.Note.Text);
                }
            }
            finally
            {
                _filling = false;
            }

            var importing = _form.Step == ForeignImportStep.Importing;
            _summary.Text = importing ? Strings.Get("ImportAppImporting") : SummaryText(_form.Summary);
            _dialog.IsPrimaryButtonEnabled = _form.CanImport;
        }

        private static void Resolutions(ConnectionRow row, ComboBox box, ForeignConnectionLine line)
        {
            if (!row.Offered.SequenceEqual(line.Offered))
            {
                box.Items.Clear();
                foreach (var offered in line.Offered)
                {
                    box.Items.Add(ResolutionText(offered));
                }

                row.Offered = line.Offered;
            }

            var index = line.Resolution is { } chosen ? IndexOf(line.Offered, chosen) : -1;
            box.SelectedIndex = index >= 0 ? index : Math.Min(0, line.Offered.Count - 1);
            box.Visibility = line.ShowsResolution ? Visibility.Visible : Visibility.Collapsed;
            box.IsEnabled = line.CanResolve;
        }

        private static int IndexOf(IReadOnlyList<ForeignResolution> offered, ForeignResolution chosen)
        {
            for (var index = 0; index < offered.Count; index++)
            {
                if (offered[index] == chosen)
                {
                    return index;
                }
            }

            return -1;
        }
    }
}
