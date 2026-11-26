using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Controls;
using Microsoft.Windows.Storage.Pickers;
using TablePro.App.Model;
using TablePro.App.Services;
using TablePro.Interop;

namespace TablePro.App.Views;

// The import sheet's content: the dialog hosts it to pick one app, the setup guide to read its ticked apps in turn.
internal sealed class ImportFromAppPanel : IDisposable
{
    private const double ConnectionsHeight = 320;
    private const double QueriesHeight = 180;
    private const double ResolutionWidth = 220;
    private const double NoteIndent = 28;

    private readonly FrameworkElement _owner;
    private readonly Workbench _workbench;
    private readonly IForeignImporter _importer;
    private readonly CancellationTokenSource _closed = new();
    private readonly List<Task> _pending = [];
    private readonly List<ForeignImportEnding> _endings = [];

    // Null for the dialog, which picks one app; the guide's ticked apps otherwise.
    private readonly IReadOnlyList<ForeignSource>? _queue;
    private readonly IReadOnlyList<ForeignSource> _sources;
    private readonly bool _queuePasswords;
    private readonly bool _queueQueries;
    private int _next;

    private readonly StackPanel _choosePage = new() { Spacing = 16 };
    private readonly StackPanel _looking = new() { Orientation = Orientation.Horizontal, Spacing = 12 };
    private readonly RadioButtons _sourceButtons = new();
    private readonly CheckBox _passwords = new();
    private readonly TextBlock _passwordsNote = Secondary(string.Empty, NoteIndent);
    private readonly CheckBox _queries = new();
    private readonly TextBlock _queriesNote = Secondary(string.Empty, NoteIndent);
    private readonly InfoBar _failure = new() { IsClosable = false, Severity = InfoBarSeverity.Error };

    private readonly StackPanel _failedPage = new() { Spacing = 16 };
    private readonly InfoBar _queueFailure = new() { IsClosable = false, Severity = InfoBarSeverity.Error };

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

    private ForeignImportForm _form;
    private bool _picking;
    private bool _failed;
    private bool _finished;

    // Set while the boxes are set from the form, whose events then are not the user's.
    private bool _filling;

    // The dialog's: the apps are looked for, and one is picked.
    public ImportFromAppPanel(FrameworkElement owner, Workbench workbench, IForeignImporter importer)
        : this(owner, workbench, importer, null, [], wantsPasswords: true, wantsQueries: true)
    {
    }

    // The guide's: the apps it ticked, in its list order, read with the options it asked for.
    public ImportFromAppPanel(
        FrameworkElement owner,
        Workbench workbench,
        IForeignImporter importer,
        IReadOnlyList<ForeignSource>? queue,
        IReadOnlyList<ForeignSource> sources,
        bool wantsPasswords,
        bool wantsQueries)
    {
        _owner = owner;
        _workbench = workbench;
        _importer = importer;
        _queue = queue;
        _sources = sources;
        _queuePasswords = wantsPasswords;
        _queueQueries = wantsQueries;
        _form = new ForeignImportForm(importer);
        LayOutChoose();
        LayOutReading();
        LayOutReview();
        _failedPage.Children.Add(Named(_queueFailure, "ImportAppFailure"));
        // The guide never shows the app list, so its first page is the read the queue starts with.
        Page = queue is null ? _choosePage : _readingPage;
    }

    // The host shows Page, Title and the primary button again after each change.
    public event EventHandler? Changed;

    // Each import that ran, refused or not.
    public event EventHandler<ForeignImportEnding>? Imported;

    // The dialog's import ended, or the guide's last app was read.
    public event EventHandler? Finished;

    public UIElement Page { get; private set; }

    public string Title { get; private set; } = Strings.Get("ImportAppTitle");

    // Empty hides the primary button.
    public string PrimaryText { get; private set; } = Strings.Get("ImportAppContinue");

    public bool CanPrimary { get; private set; }

    public bool IsImporting => _form.Step == ForeignImportStep.Importing;

    public ForeignSource? CurrentSource => _form.Chosen;

    public IReadOnlyList<ForeignImportEnding> Endings => _endings;

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

    // What the source list says under an app's name: its counts, or why it cannot be picked.
    public static string SourceText(ForeignSource source)
    {
        ArgumentNullException.ThrowIfNull(source);
        switch (ForeignImportForm.NoteFor(source))
        {
            case ForeignSourceNote.PicksFile:
                return Strings.Get("ImportAppSourceFile");
            case ForeignSourceNote.NotFound:
                return Strings.Get("ImportAppSourceNotFound");
            case ForeignSourceNote.Unreadable
                when source.Availability is ForeignSourceAvailability.Unreadable unreadable:
                var failure = ForeignReadFailure.From(
                    source.App,
                    new CoreError(unreadable.Code, [unreadable.Code], unreadable.Detail, null, null));
                return FailureText(failure, source.Name);
        }

        var connections = Strings.Plural("ImportAppSourceConnections", source.Connections, source.Connections);
        if (source.SavedQueries == 0)
        {
            return connections;
        }

        var queries = Strings.Plural("ImportAppSourceQueries", source.SavedQueries, source.SavedQueries);
        return Strings.Format("JoinDot", connections, queries);
    }

    // The core's own text on a source it could not read, for the row's tooltip.
    public static string? UnreadableDetail(ForeignSource source) =>
        source.Availability is ForeignSourceAvailability.Unreadable unreadable ? unreadable.Detail : null;

    public void Start()
    {
        if (_queue is null)
        {
            Track(LoadAsync());
        }
        else
        {
            Track(NextAppAsync());
        }
    }

    public void Primary()
    {
        if (_failed)
        {
            Track(NextAppAsync());
            return;
        }

        switch (_form.Step)
        {
            case ForeignImportStep.Choosing:
                Track(ContinueAsync());
                break;
            case ForeignImportStep.Reviewing when _form.CanImport:
                Track(ImportAsync());
                break;
            case ForeignImportStep.Reviewing when _queue is not null:
                Track(NextAppAsync());
                break;
        }
    }

    // A read is cancelled with the host; an import cannot stop halfway, so the host waits for it.
    public void Cancel() => _closed.Cancel();

    public async Task WhenIdleAsync()
    {
        await Task.WhenAll(_pending).ConfigureAwait(true);
    }

    public void Dispose()
    {
        _form.Dispose();
        _closed.Dispose();
    }

    // A style keeps the host's own theme, which a brush read from the app's resources in code would not.
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

    private static string Sentence(ForeignImportSentence sentence, CoreError? error) => sentence.Part switch
    {
        ForeignImportPart.Nothing => Strings.Get("ImportAppDone_Nothing"),
        ForeignImportPart.Outdated => Strings.Get("ImportAppDone_Outdated"),
        ForeignImportPart.Failed when error is not null =>
            Strings.Sentences(Strings.Get("ImportAppDone_Failed"), Strings.Error(error)),
        ForeignImportPart.Failed => Strings.Get("ImportAppDone_Failed"),
        _ => Strings.Plural("ImportAppDone_" + sentence.Part, sentence.Count, sentence.Count),
    };

    private static string FailureText(ForeignReadFailure failure, string appName) => failure.Kind switch
    {
        ForeignReadFailureKind.Library or ForeignReadFailureKind.Other => Strings.Get("ImportAppRead_" + failure.Kind),
        _ => Strings.Format("ImportAppRead_" + failure.Kind, appName),
    };

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

    private static StackPanel Option(CheckBox box, TextBlock note, string name)
    {
        box.Content = Strings.Get(name);
        Named(box, name, Strings.Get(name));
        var panel = new StackPanel { Spacing = 2 };
        panel.Children.Add(box);
        panel.Children.Add(Named(note, name + "Note"));
        return panel;
    }

    private string AppName => _form.Chosen?.Name ?? string.Empty;

    private void LayOutChoose()
    {
        _looking.Children.Add(new ProgressRing { IsActive = true, Width = 20, Height = 20 });
        _looking.Children.Add(new TextBlock
        {
            Text = Strings.Get("ImportAppLooking"),
            VerticalAlignment = VerticalAlignment.Center,
        });
        _choosePage.Children.Add(_looking);

        _sourceButtons.Header = Strings.Get("ImportAppSourcesHeader");
        Named(_sourceButtons, "ImportAppSources", Strings.Get("ImportAppSourcesHeader"));
        _sourceButtons.SelectionChanged += (_, _) => OnSourceChosen();
        _choosePage.Children.Add(_sourceButtons);

        _choosePage.Children.Add(Option(_passwords, _passwordsNote, "ImportAppPasswords"));
        _passwords.Checked += (_, _) => OnOption();
        _passwords.Unchecked += (_, _) => OnOption();
        _choosePage.Children.Add(Option(_queries, _queriesNote, "ImportAppQueries"));
        _queries.Checked += (_, _) => OnOption();
        _queries.Unchecked += (_, _) => OnOption();

        _choosePage.Children.Add(Named(_failure, "ImportAppFailure"));
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

    // The guide's next ticked app, read at once; none left ends the queue.
    private async Task NextAppAsync()
    {
        if (_queue is null || _closed.IsCancellationRequested)
        {
            return;
        }

        _failed = false;
        if (_next >= _queue.Count)
        {
            Finish();
            return;
        }

        var app = _queue[_next++].App;
        _form.Dispose();
        _form = new ForeignImportForm(_importer, _sources, app);
        _form.SetPasswords(_queuePasswords);
        _form.SetQueries(_queueQueries);
        if (!_form.CanContinue)
        {
            await NextAppAsync().ConfigureAwait(true);
            return;
        }

        await ContinueAsync().ConfigureAwait(true);
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
                if (UnreadableDetail(source) is { } detail)
                {
                    ToolTipService.SetToolTip(button, detail);
                }

                _sourceButtons.Items.Add(button);
            }

            _sourceButtons.SelectedIndex = _form.Chosen is { } chosen
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
        if (_filling || _sourceButtons.SelectedItem is not RadioButton { Tag: ForeignApp app })
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
        if (_failed)
        {
            Page = _failedPage;
            PrimaryText = Strings.Get("ImportAppContinue");
            CanPrimary = true;
            Changed?.Invoke(this, EventArgs.Empty);
            return;
        }

        switch (_form.Step)
        {
            case ForeignImportStep.Loading:
            case ForeignImportStep.Choosing:
                ShowChoose();
                break;
            case ForeignImportStep.Reading:
                Title = Strings.Format("ImportAppReviewTitle", AppName);
                Page = _readingPage;
                PrimaryText = string.Empty;
                CanPrimary = false;
                _readingText.Text = Strings.Format("ImportAppReading", AppName);
                break;
            default:
                Title = Strings.Format("ImportAppReviewTitle", AppName);
                Page = _reviewPage;
                RefreshReview();
                break;
        }

        Changed?.Invoke(this, EventArgs.Empty);
    }

    private void ShowChoose()
    {
        var loading = _form.Step == ForeignImportStep.Loading;
        Title = Strings.Get("ImportAppTitle");
        Page = _choosePage;
        PrimaryText = Strings.Get("ImportAppContinue");
        CanPrimary = _form.CanContinue && !_picking;
        _looking.Visibility = loading ? Visibility.Visible : Visibility.Collapsed;
        _sourceButtons.Visibility = loading || _form.Sources.Count == 0 ? Visibility.Collapsed : Visibility.Visible;

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

        var failure = _form.Failure is { } read ? FailureText(read, ReadName(read))
            : _form.SourcesError is not null ? Strings.Get("ImportAppSourcesFailed")
            : null;
        ShowMessage(_failure, failure);
    }

    private string ReadName(ForeignReadFailure failure) =>
        _form.Sources.FirstOrDefault(source => source.App == failure.App)?.Name ?? AppName;

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
            CanPrimary = false;
            if (_queue is null)
            {
                Changed?.Invoke(this, EventArgs.Empty);
            }

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
                if (_queue is not null && !_closed.IsCancellationRequested)
                {
                    await NextAppAsync().ConfigureAwait(true);
                    return;
                }

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
        else if (_queue is not null && _form.Failure is { } failure)
        {
            // The guide goes on to the next app once the user has read why this one stopped.
            _failed = true;
            ShowMessage(_queueFailure, FailureText(failure, ReadName(failure)));
        }

        if (!_closed.IsCancellationRequested)
        {
            Show();
        }
    }

    // The picker belongs to the window the host is in.
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
        CanPrimary = false;
        _connectionList.IsEnabled = false;
        _queryList.IsEnabled = false;
        _summary.Text = Strings.Get("ImportAppImporting");
        Changed?.Invoke(this, EventArgs.Empty);
        if (await importing.ConfigureAwait(true) is { } ending)
        {
            _endings.Add(ending);
            Imported?.Invoke(this, ending);
        }

        _connectionList.IsEnabled = true;
        _queryList.IsEnabled = true;
        if (_queue is null)
        {
            Finish();
        }
        else
        {
            await NextAppAsync().ConfigureAwait(true);
        }
    }

    private void Finish()
    {
        if (!_finished)
        {
            _finished = true;
            Finished?.Invoke(this, EventArgs.Empty);
        }
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
        Changed?.Invoke(this, EventArgs.Empty);
    }

    private void OnResolved(ConnectionRow row)
    {
        if (_filling || row.Resolution is not { SelectedIndex: >= 0 } box || box.SelectedIndex >= row.Offered.Count)
        {
            return;
        }

        _form.Resolve(row.Reference, row.Offered[box.SelectedIndex]);
        RefreshReview();
        Changed?.Invoke(this, EventArgs.Empty);
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
        Changed?.Invoke(this, EventArgs.Empty);
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
        // The guide moves past an app with nothing checked; the dialog waits for a row.
        PrimaryText = Strings.Get(_form.CanImport || _queue is null ? "ImportAppAction" : "ImportAppContinue");
        CanPrimary = _form.CanImport || (_queue is not null && !importing);
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
}
