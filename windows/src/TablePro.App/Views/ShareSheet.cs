using System.Globalization;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Automation.Peers;
using Microsoft.UI.Xaml.Controls;
using TablePro.App.Model;
using TablePro.App.Services;
using TablePro.DataGrid;
using TablePro.DataGrid.Model;
using TablePro.Interop;
using Windows.System;

namespace TablePro.App.Views;

// A query's text, a finished result with the SQL that made it, or a table view the sheet reads once it knows the plan.
internal sealed record ShareSubject(
    ShareKind Kind,
    string Sql,
    string Title,
    string? Dialect,
    ResultSet? Rows,
    IReadOnlyList<ResultColumn> Columns,
    Func<long, CancellationToken, Task<TableShareRead>>? ReadTable = null)
{
    public long TotalRows => Rows?.RowCount ?? 0;

    public static ShareSubject Query(string sql, string title, string? dialect) =>
        new(ShareKind.Query, sql, title, dialect, null, []);

    public static ShareSubject Result(
        string sql, string title, string? dialect, ResultSet rows, IReadOnlyList<ResultColumn> columns) =>
        new(ShareKind.Result, sql, title, dialect, rows, columns);

    // The view is read from its first row up to the plan's rows, so the sheet reads it after the limits.
    public static ShareSubject Table(
        string title, string? dialect, Func<long, CancellationToken, Task<TableShareRead>> read) =>
        new(ShareKind.Result, string.Empty, title, dialect, null, [], read);
}

// What the link sends; ViewCount is a table view's row count, which its one page of rows cannot tell.
internal sealed record SharedContent(
    string Sql,
    ResultSet? Rows,
    IReadOnlyList<ResultColumn> Columns,
    long TotalRows,
    long? ViewCount);

// One section at a time follows the account and the plan's limits; SharePlan holds the rules (decision 0009).
internal sealed class ShareSheet
{
    // The list of live links at the cap is read a page at a time, up to Pro's limit.
    private const int MostListPages = 20;

    private readonly Workbench _workbench;
    private readonly ShareSubject _subject;

    // Cancelled when the sheet closes, so a table read it started stops with it.
    private readonly CancellationToken _closing;
    private readonly ContentDialog _dialog;
    private readonly StackPanel _busy = new() { Orientation = Orientation.Horizontal, Spacing = 12 };
    private readonly TextBlock _busyText = new() { VerticalAlignment = VerticalAlignment.Center, TextWrapping = TextWrapping.Wrap };
    private readonly InfoBar _notice = new() { IsClosable = false };
    private readonly StackPanel _form = new() { Spacing = 12 };
    private readonly TextBox _title = new() { MaxLength = 200 };
    private readonly TextBox _note = new() { MaxLength = 2000, AcceptsReturn = true, TextWrapping = TextWrapping.Wrap, MinHeight = 64 };
    private readonly ComboBox _expires = new() { MinWidth = 200 };
    private readonly CheckBox _hideSql = new();
    private readonly PasswordBox _password = new() { MaxLength = 128 };
    private readonly CheckBox _allowDownload = new() { IsChecked = true };
    private readonly HyperlinkButton _expiresPro = ProTag();
    private readonly HyperlinkButton _passwordPro = ProTag();
    private readonly HyperlinkButton _downloadPro = ProTag();
    private readonly StackPanel _preview = new() { Spacing = 8 };
    private readonly TextBlock _capNote = new() { TextWrapping = TextWrapping.Wrap };
    private readonly TextBlock _noSql = new() { TextWrapping = TextWrapping.Wrap, Visibility = Visibility.Collapsed };
    private readonly TextBlock _columnsNote = new() { TextWrapping = TextWrapping.Wrap, Visibility = Visibility.Collapsed };
    private readonly TextBlock _doneNote = new() { TextWrapping = TextWrapping.Wrap, Visibility = Visibility.Collapsed };
    private readonly ComboBox _owners = new() { MinWidth = 200 };
    private readonly InfoBar _secrets = new() { IsClosable = false, Severity = InfoBarSeverity.Warning };
    private readonly InfoBar _personalData = new() { IsClosable = false, Severity = InfoBarSeverity.Warning };
    private readonly StackPanel _columnsSection = new() { Spacing = 8 };
    private readonly StackPanel _columnsList = new() { Spacing = 8 };
    private readonly TextBlock _columnsSummary = new() { TextWrapping = TextWrapping.Wrap };
    private readonly TextBlock _detectionNote = new() { TextWrapping = TextWrapping.Wrap, Visibility = Visibility.Collapsed };
    private readonly InfoBar _noColumns = new() { IsClosable = false, Severity = InfoBarSeverity.Error };
    private readonly InfoBar _tooLarge = new() { IsClosable = false, Severity = InfoBarSeverity.Error };
    private readonly InfoBar _error = new() { IsClosable = true, Severity = InfoBarSeverity.Error };
    private readonly InfoBar _fieldProblems = new() { IsClosable = false, Severity = InfoBarSeverity.Error };
    private readonly StackPanel _atCap = new() { Spacing = 12 };
    private readonly StackPanel _done = new() { Spacing = 12 };
    private readonly TextBox _url = new() { IsReadOnly = true };
    private readonly TextBlock _footer = new();
    private DataGridView? _previewGrid;

    // The set the preview grid reads, which the core masked and cut as the link will be.
    private ResultSet? _previewRows;

    // Read once per content: what the detectors saw, then the user's choices.
    private ShareColumns? _columns;
    private SharedContent? _columnsFor;

    // The form's plan, what the link sends with the choices as they are now, and whether the preview shows it yet.
    private readonly ShareRounds _rounds = new();
    private SharedContent _content;
    private TableShareRead? _tableRead;
    private long _tableReadFor = -1;
    private ShareLimits? _limits;

    // Share as: null for a personal link, else the team's id.
    private string? _teamId;
    private bool _listingOwners;
    private AccountStage _stage;
    private int _generation;
    private bool _creating;
    private bool _created;
    private bool _closed;

    private ShareSheet(FrameworkElement owner, Workbench workbench, ShareSubject subject, CancellationToken closing)
    {
        _workbench = workbench;
        _subject = subject;
        _closing = closing;
        _content = new SharedContent(subject.Sql, subject.Rows, subject.Columns, subject.TotalRows, null);
        _dialog = new ContentDialog
        {
            RequestedTheme = owner.ActualTheme,
            Title = Strings.Get(subject.Kind == ShareKind.Result ? "ShareResultTitle" : "ShareQueryTitle"),
            Content = Layout(),
            PrimaryButtonText = Strings.Get("ShareAction"),
            // The dialog's own action, as Save is the connection form's; it stays off until a share is allowed.
            PrimaryButtonStyle = (Style)Application.Current.Resources["AccentButtonStyle"],
            CloseButtonText = Strings.Get("Cancel"),
            DefaultButton = ContentDialogButton.Primary,
            IsPrimaryButtonEnabled = false,
        };
        _dialog.PrimaryButtonClick += OnShare;
    }

    // One at a time per window, as every ContentDialog; another dialog open declines it.
    public static async Task ShowAsync(FrameworkElement owner, Workbench workbench, ShareSubject subject)
    {
        ArgumentNullException.ThrowIfNull(owner);
        ArgumentNullException.ThrowIfNull(workbench);
        ArgumentNullException.ThrowIfNull(subject);
        if (WindowDialogs.IsOpen(owner.XamlRoot))
        {
            return;
        }

        using var lifetime = new CancellationTokenSource();
        var sheet = new ShareSheet(owner, workbench, subject, lifetime.Token);
        workbench.AccountChanged += sheet.OnAccountChanged;
        try
        {
            sheet._stage = workbench.AccountPanel.Stage;
            _ = sheet.LoadAsync();
            await WindowDialogs.ShowAsync(sheet._dialog, owner).ConfigureAwait(true);
        }
        finally
        {
            sheet._closed = true;
            await lifetime.CancelAsync().ConfigureAwait(true);
            workbench.AccountChanged -= sheet.OnAccountChanged;
            // The grid gives its cursor back here, before the result set can go.
            sheet._previewGrid?.SetData(null);
            sheet._previewRows?.Dispose();
            sheet._tableRead?.Dispose();
        }
    }

    private ScrollViewer Layout()
    {
        _busy.Children.Add(new ProgressRing { IsActive = true, Width = 20, Height = 20 });
        _busy.Children.Add(_busyText);
        AutomationProperties.SetAutomationId(_notice, "ShareNotice");

        _title.Header = Strings.Get("ShareTitleField");
        _title.Text = _subject.Title;
        AutomationProperties.SetAutomationId(_title, "ShareTitleBox");
        _note.Header = Strings.Get("ShareNoteField");
        _note.PlaceholderText = Strings.Get("ShareNotePlaceholder");
        AutomationProperties.SetAutomationId(_note, "ShareNoteBox");
        _expires.Header = Strings.Get("ShareExpiresField");
        AutomationProperties.SetAutomationId(_expires, "ShareExpiresBox");
        _hideSql.Content = Strings.Get("ShareHideSql");
        _hideSql.Checked += (_, _) => ShowSecrets();
        _hideSql.Unchecked += (_, _) => ShowSecrets();
        AutomationProperties.SetAutomationId(_hideSql, "ShareHideSql");
        _password.Header = Strings.Get("SharePasswordField");
        AutomationProperties.SetAutomationId(_password, "SharePasswordBox");
        _allowDownload.Content = Strings.Get("ShareAllowDownload");
        AutomationProperties.SetAutomationId(_allowDownload, "ShareAllowDownload");

        _owners.Header = Strings.Get("ShareAsField");
        AutomationProperties.SetAutomationId(_owners, "ShareAsBox");
        _owners.SelectionChanged += OnOwnerChanged;
        _form.Children.Add(_title);
        _form.Children.Add(_note);
        _form.Children.Add(WithTag(_expires, _expiresPro));
        if (_subject.Kind == ShareKind.Result)
        {
            _form.Children.Add(_hideSql);
            var hide = new Button { Content = Strings.Get("ShareHideSql") };
            AutomationProperties.SetAutomationId(hide, "ShareHideSqlButton");
            // The notice closes as Hide SQL turns on, so focus moves to the box that now says so.
            hide.Click += (_, _) =>
            {
                _hideSql.IsChecked = true;
                _hideSql.Focus(FocusState.Programmatic);
            };
            _personalData.ActionButton = hide;
            _personalData.Visibility = Visibility.Collapsed;
            AutomationProperties.SetAutomationId(_personalData, "ShareHideSqlSuggestion");
            _form.Children.Add(_personalData);
            _noSql.Text = Strings.Get("ShareTableNoSql");
            AutomationProperties.SetAutomationId(_noSql, "ShareTableNoSql");
            _form.Children.Add(_noSql);
        }

        _form.Children.Add(WithTag(_password, _passwordPro));
        _password.PasswordChanged += (_, _) => ShowFieldProblems();
        _fieldProblems.Visibility = Visibility.Collapsed;
        AutomationProperties.SetAutomationId(_fieldProblems, "ShareFieldProblems");
        _form.Children.Add(_fieldProblems);
        _form.Children.Add(WithTag(_allowDownload, _downloadPro));
        if (_subject.Kind == ShareKind.Result)
        {
            _preview.Children.Add(new TextBlock
            {
                Text = Strings.Get("SharePreviewHeader"),
                Style = (Style)Application.Current.Resources["BodyStrongTextBlockStyle"],
            });
            // As the macOS preview: a long value ends in an ellipsis at 200 px, and its tooltip shows it whole.
            _previewGrid = new DataGridView
            {
                SizeColumnsToContent = true,
                MaximumContentColumnWidth = 200,
                ShowsCellTips = true,
            };
            AutomationProperties.SetName(_previewGrid, Strings.Get("SharePreviewHeader"));
            AutomationProperties.SetAutomationId(_previewGrid, "SharePreview");
            _preview.Children.Add(_previewGrid);
            _preview.Children.Add(_capNote);
            AutomationProperties.SetAutomationId(_columnsNote, "ShareColumnsNote");
            _preview.Children.Add(_columnsNote);
            _noColumns.Message = Strings.Get("ShareNoColumns");
            _noColumns.Visibility = Visibility.Collapsed;
            AutomationProperties.SetAutomationId(_noColumns, "ShareNoColumns");
            _preview.Children.Add(_noColumns);
            _tooLarge.Visibility = Visibility.Collapsed;
            AutomationProperties.SetAutomationId(_tooLarge, "ShareTooLarge");
            _preview.Children.Add(_tooLarge);
            _form.Children.Add(_preview);

            _columnsSection.Children.Add(new TextBlock
            {
                Text = Strings.Get("ShareColumnsHeader"),
                Style = (Style)Application.Current.Resources["BodyStrongTextBlockStyle"],
            });
            AutomationProperties.SetAutomationId(_columnsList, "ShareColumns");
            AutomationProperties.SetName(_columnsList, Strings.Get("ShareColumnsHeader"));
            _columnsSection.Children.Add(_columnsList);
            _columnsSummary.Style = Caption;
            AutomationProperties.SetAutomationId(_columnsSummary, "ShareColumnsSummary");
            AutomationProperties.SetLiveSetting(_columnsSummary, Microsoft.UI.Xaml.Automation.Peers.AutomationLiveSetting.Polite);
            _columnsSection.Children.Add(_columnsSummary);
            _detectionNote.Text = Strings.Get("ShareColumnsDetected");
            _detectionNote.Style = Caption;
            AutomationProperties.SetAutomationId(_detectionNote, "ShareColumnsDetected");
            _columnsSection.Children.Add(_detectionNote);
            _form.Children.Add(_columnsSection);
        }

        AutomationProperties.SetAutomationId(_secrets, "ShareSecrets");
        _form.Children.Add(_secrets);
        AutomationProperties.SetAutomationId(_error, "ShareError");
        _form.Children.Add(_error);

        _url.Header = Strings.Get("ShareLinkCopied");
        AutomationProperties.SetAutomationId(_url, "ShareUrl");
        var copy = new Button { Content = Strings.Get("ShareCopy") };
        AutomationProperties.SetAutomationId(copy, "ShareCopy");
        copy.Click += (_, _) => WorkspaceView.CopyText(_url.Text);
        var open = new Button { Content = Strings.Get("ShareOpenInBrowser") };
        AutomationProperties.SetAutomationId(open, "ShareOpenInBrowser");
        open.Click += async (_, _) => await OpenAsync(_url.Text).ConfigureAwait(true);
        var actions = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 8 };
        actions.Children.Add(copy);
        actions.Children.Add(open);
        _done.Children.Add(_url);
        _done.Children.Add(actions);
        AutomationProperties.SetAutomationId(_doneNote, "ShareColumnsShared");
        _done.Children.Add(_doneNote);

        _footer.Style = Caption;
        AutomationProperties.SetAutomationId(_footer, "ShareFooter");

        // The right padding keeps the scroll bar off the rows' dropdowns.
        var root = new StackPanel { Spacing = 12, MinWidth = 400, Padding = new Thickness(0, 0, ScrollBarGutter, 0) };
        AutomationProperties.SetAutomationId(root, "ShareSheet");
        foreach (var part in new UIElement[] { _busy, _notice, _owners, _form, _atCap, _done, _footer })
        {
            part.Visibility = Visibility.Collapsed;
            root.Children.Add(part);
        }

        return new ScrollViewer { Content = root, MaxHeight = 560 };
    }

    private const double ActionWidth = 120;
    private const double StyleWidth = 180;
    private const double ScrollBarGutter = 16;

    // Room under the preview's rows for its horizontal scroll bar, so a column past the edge can be scrolled to.
    private const double PreviewScrollBarRoom = 16;

    // A style keeps the dialog's own theme, which a brush read from the app's resources in code would not.
    private static Style Caption => (Style)Application.Current.Resources["CaptionTextBlockStyle"];

    private static HyperlinkButton ProTag()
    {
        var tag = new HyperlinkButton
        {
            Content = Strings.Get("ProTag"),
            NavigateUri = AccountSetup.PricingUri,
            VerticalAlignment = VerticalAlignment.Bottom,
            Visibility = Visibility.Collapsed,
        };
        AutomationProperties.SetName(tag, Strings.Get("ProTagName"));
        return tag;
    }

    private static Grid WithTag(FrameworkElement field, HyperlinkButton tag)
    {
        var row = new Grid { ColumnSpacing = 8 };
        row.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        row.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        field.HorizontalAlignment = field is CheckBox ? HorizontalAlignment.Left : HorizontalAlignment.Stretch;
        row.Children.Add(field);
        Grid.SetColumn(tag, 1);
        row.Children.Add(tag);
        return row;
    }

    // A sign-in or sign-out changes what the sheet can offer; a refresh that keeps the stage changes nothing here.
    private void OnAccountChanged(object? sender, EventArgs e)
    {
        var stage = _workbench.AccountPanel.Stage;
        if (_closed || _created || _creating || stage == _stage)
        {
            return;
        }

        _stage = stage;
        _ = LoadAsync();
    }

    private async Task LoadAsync()
    {
        var generation = ++_generation;
        _rounds.Show(null);
        _dialog.IsPrimaryButtonEnabled = false;
        switch (_workbench.AccountPanel.Stage)
        {
            case AccountStage.Unavailable:
                var failure = _workbench.AccountFailure;
                var message = failure is null ? Strings.Get(ShareErrors.Failed) : Strings.Error(failure);
                ShowNotice(InfoBarSeverity.Error, message, null);
                return;
            case AccountStage.SigningIn:
                ShowBusy(Strings.Get("ShareSigningIn"), Strings.Get("Cancel"), _workbench.CancelSignIn);
                return;
            case AccountStage.SignedIn:
                break;
            default:
                ShowSignedOut();
                return;
        }

        ShowBusy(Strings.Get("ShareLoading"));
        try
        {
            if (await _workbench.GetAccountAsync().ConfigureAwait(true) is not { } account)
            {
                ShowSignedOut();
                return;
            }

            var limits = await account.GetShareLimitsAsync().ConfigureAwait(true);
            if (generation == _generation && !_closed)
            {
                await ApplyAsync(account, limits, generation).ConfigureAwait(true);
            }
        }
        catch (TableProException exception) when (generation == _generation && !_closed)
        {
            if (exception.Code == "account.signed_out")
            {
                ShowSignedOut();
                return;
            }

            var message = exception.Code == "account.unreachable"
                ? Strings.Get("ShareErrorOffline")
                : Strings.Error(exception.Error);
            ShowNotice(InfoBarSeverity.Error, message, (Strings.Get("ShareRetry"), () => _ = LoadAsync()));
        }
        catch (TableProException)
        {
            // A newer load, or the sheet closed, says what to show.
        }
        catch (OperationCanceledException) when (generation == _generation && !_closed)
        {
            ShowNotice(InfoBarSeverity.Error, Strings.Get(ShareErrors.Failed), (Strings.Get("ShareRetry"), () => _ = LoadAsync()));
        }
        catch (OperationCanceledException)
        {
            // As above.
        }
    }

    private void ShowSignedOut() =>
        ShowNotice(
            InfoBarSeverity.Informational,
            Strings.Get("ShareErrorSignedOut"),
            (Strings.Get("ShareSignIn"), () => _ = SignInAsync()),
            "ShareSignInButton");

    private async Task SignInAsync()
    {
        try
        {
            await _workbench.SignInAsync().ConfigureAwait(true);
        }
        catch (TableProException exception)
        {
            if (!_closed)
            {
                ShowNotice(
                    InfoBarSeverity.Error,
                    Strings.Error(exception.Error),
                    (Strings.Get("ShareSignIn"), () => _ = SignInAsync()),
                    "ShareSignInButton");
            }
        }
    }

    private async Task ApplyAsync(TableProAccount account, ShareLimits limits, int generation)
    {
        _limits = limits;
        var plan = Plan(limits);
        // Share and Enter stay off until the form shows, so an owner at its cap never creates with the last plan.
        _rounds.Show(null);
        UpdateShareButton();
        ListOwners(plan);
        _footer.Text = plan.Footer switch
        {
            { Team: { } team } footer => Strings.Format("ShareFooterTeam", team, footer.Live, footer.Limit),
            { Pro: true } footer => Strings.Format(footer.ProKey, footer.Live),
            var footer => Strings.Format("ShareFooterFree", footer.Live, footer.Limit, footer.MaxRows),
        };
        switch (plan.Stage)
        {
            case ShareStage.EmailUnverified:
                ShowNotice(
                    InfoBarSeverity.Warning,
                    Strings.Get("ShareErrorEmailUnverified"),
                    (Strings.Get("ShareOpenAccount"), () => _ = OpenAsync(_workbench.Portal.AbsoluteUri)));
                break;
            case ShareStage.SharingDisabled:
                ShowNotice(InfoBarSeverity.Warning, Strings.Get("ShareErrorSharingDisabled"), null);
                break;
            case ShareStage.AtCap:
                await ShowAtCapAsync(account, plan, generation).ConfigureAwait(true);
                break;
            default:
                if (_subject.ReadTable is { } read && _tableReadFor != limits.MaxRows)
                {
                    await ReadTableAsync(read, limits.MaxRows).ConfigureAwait(true);
                    if (generation != _generation || _closed)
                    {
                        return;
                    }

                    plan = Plan(limits);
                }

                ShowForm(plan);
                break;
        }
    }

    private SharePlan Plan(ShareLimits limits) =>
        SharePlan.For(limits, _subject.Kind, _content.TotalRows, _content.Sql.Length > 0, _teamId);

    // Personal, then each seated team; the picker shows only when there is a team to pick.
    private void ListOwners(SharePlan plan)
    {
        _listingOwners = true;
        try
        {
            _owners.Items.Clear();
            foreach (var owner in plan.Owners)
            {
                var name = owner.Name ?? Strings.Get("ShareAsPersonal");
                _owners.Items.Add(new ComboBoxItem
                {
                    Content = owner.Enabled ? name : Strings.Format("ShareAsTeamOff", name),
                    Tag = owner.TeamId,
                    IsEnabled = owner.Enabled,
                });
            }

            _owners.SelectedItem = _owners.Items.OfType<ComboBoxItem>()
                .First(item => (item.Tag as string) == plan.TeamId);
        }
        finally
        {
            _listingOwners = false;
        }
    }

    // A team's own count and links decide the cap, so the sheet applies the limits it holds again.
    private async void OnOwnerChanged(object sender, SelectionChangedEventArgs e)
    {
        if (_listingOwners || _creating || _created || _closed || _limits is not { } limits
            || _owners.SelectedItem is not ComboBoxItem { IsEnabled: true } item)
        {
            return;
        }

        var teamId = item.Tag as string;
        if (teamId == _teamId)
        {
            return;
        }

        _teamId = teamId;
        var generation = ++_generation;
        try
        {
            if (await _workbench.GetAccountAsync().ConfigureAwait(true) is { } account && generation == _generation)
            {
                await ApplyAsync(account, limits, generation).ConfigureAwait(true);
            }
        }
        catch (TableProException exception)
        {
            if (generation == _generation && !_closed)
            {
                ShowNotice(InfoBarSeverity.Error, Strings.Error(exception.Error), (Strings.Get("ShareRetry"), () => _ = LoadAsync()));
            }
        }
    }

    // The preview and the link both take these rows, so they are read once per plan.
    private async Task ReadTableAsync(Func<long, CancellationToken, Task<TableShareRead>> read, long maxRows)
    {
        ShowBusy(Strings.Get("ShareReadingRows"));
        var table = await read(maxRows, _closing).ConfigureAwait(true);
        if (_closed)
        {
            table.Dispose();
            return;
        }

        _previewGrid?.SetData(null);
        _previewRows?.Dispose();
        _previewRows = null;
        _tableRead?.Dispose();
        _tableRead = table;
        _tableReadFor = maxRows;
        var columns = table.Rows?.GetColumns().Take(table.VisibleColumns).ToList() ?? [];
        _content = new SharedContent(table.ViewSql ?? string.Empty, table.Rows, columns, table.TotalRows, table.TotalRows);
        _noSql.Visibility = table.ViewSql is null ? Visibility.Visible : Visibility.Collapsed;
    }

    private void ShowForm(SharePlan plan)
    {
        _rounds.Show(plan);
        var picked = (_expires.SelectedItem as ComboBoxItem)?.Tag as ShareExpiry?;
        _expires.Items.Clear();
        foreach (var choice in plan.Expiries)
        {
            var name = Strings.Get("Expiry_" + choice.Expiry);
            _expires.Items.Add(new ComboBoxItem
            {
                Content = choice.ProTag ? Strings.Format("ExpiryWithProTag", name, Strings.Get("ProTag")) : name,
                Tag = choice.Expiry,
                IsEnabled = choice.Enabled,
            });
        }

        var selected = plan.Expiries.Any(choice => choice.Enabled && choice.Expiry == picked) ? picked : plan.DefaultExpiry;
        _expires.SelectedItem = _expires.Items.OfType<ComboBoxItem>().First(item => (ShareExpiry)item.Tag == selected);
        _expiresPro.Visibility = plan.Expiries.Any(choice => choice.ProTag) ? Visibility.Visible : Visibility.Collapsed;
        _password.IsEnabled = plan.PasswordAllowed;
        _passwordPro.Visibility = plan.PasswordAllowed ? Visibility.Collapsed : Visibility.Visible;
        _allowDownload.IsEnabled = plan.DownloadChoiceAllowed;
        _downloadPro.Visibility = plan.DownloadChoiceAllowed ? Visibility.Collapsed : Visibility.Visible;
        if (!plan.DownloadChoiceAllowed)
        {
            _allowDownload.IsChecked = true;
        }

        _hideSql.Visibility = plan.OffersHideSql ? Visibility.Visible : Visibility.Collapsed;
        if (!plan.OffersHideSql)
        {
            _hideSql.IsChecked = false;
        }

        if (_rounds.Summary is null)
        {
            _capNote.Visibility = Visibility.Collapsed;
            _columnsNote.Visibility = Visibility.Collapsed;
        }

        Show(_form);
        ShowFieldProblems();
        if (_subject.Kind == ShareKind.Result && !ReferenceEquals(_columnsFor, _content))
        {
            _ = LoadColumnsAsync(plan);
        }

        ColumnsChanged();
    }

    // Every column starts as PLAN-MASKING 8.4 says, so a detected one leaves masked unless the user keeps it.
    private async Task LoadColumnsAsync(SharePlan plan)
    {
        var content = _content;
        _columnsFor = content;
        _columns = null;
        _columnsList.Children.Clear();
        if (content.Rows is not { } rows)
        {
            return;
        }

        IReadOnlyList<ShareColumnMasking> masking;
        try
        {
            masking = await rows.GetShareMaskingAsync(content.Columns.Count, plan.Limits.MaxRows).ConfigureAwait(true);
        }
        catch (TableProException exception)
        {
            if (!_closed && ReferenceEquals(_content, content))
            {
                _columnsFor = null;
                // Rows too large to send stay too large, so only another failure offers Retry.
                if (exception.Code == "account.snapshot_too_large")
                {
                    ShowNotice(InfoBarSeverity.Error, Strings.Get(ShareErrors.KeyFor(exception.Code)), null);
                }
                else
                {
                    ShowNotice(InfoBarSeverity.Error, Strings.Error(exception.Error), (Strings.Get("ShareRetry"), () => _ = LoadAsync()));
                }
            }

            return;
        }
        catch (ObjectDisposedException)
        {
            if (!_closed)
            {
                ShowError(Strings.Get("ShareRowsGone"));
            }

            return;
        }

        if (_closed || !ReferenceEquals(_content, content))
        {
            return;
        }

        _columns = ShareColumns.From(masking);
        foreach (var column in _columns.Columns)
        {
            _columnsList.Children.Add(ColumnRow(column));
        }

        ColumnsChanged();
    }

    // Every row lays its controls on the same fixed columns, so a kept row's choice lines up with a masked row's.
    private Grid ColumnRow(ShareColumn column)
    {
        var row = new Grid { ColumnSpacing = 8 };
        row.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        row.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(ActionWidth) });
        row.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(StyleWidth) });
        var label = new StackPanel { VerticalAlignment = VerticalAlignment.Center };
        label.Children.Add(new TextBlock { Text = column.Name, TextTrimming = TextTrimming.CharacterEllipsis });
        var reason = Reason(column);
        if (reason is not null)
        {
            label.Children.Add(new TextBlock { Text = reason, Style = Caption, TextWrapping = TextWrapping.Wrap });
        }

        var action = new ComboBox { HorizontalAlignment = HorizontalAlignment.Stretch, VerticalAlignment = VerticalAlignment.Center };
        foreach (var each in new[] { ShareColumnAction.Keep, ShareColumnAction.Mask, ShareColumnAction.Remove })
        {
            action.Items.Add(new ComboBoxItem { Content = Strings.Get("ShareColumn_" + each), Tag = each });
        }

        action.SelectedIndex = (int)column.Action;
        AutomationProperties.SetName(action, Strings.Format("ShareColumnActionName", column.Name));
        if (reason is not null)
        {
            AutomationProperties.SetHelpText(action, reason);
        }

        var style = new ComboBox
        {
            HorizontalAlignment = HorizontalAlignment.Stretch,
            VerticalAlignment = VerticalAlignment.Center,
            Visibility = column.Action == ShareColumnAction.Mask ? Visibility.Visible : Visibility.Collapsed,
        };
        foreach (var each in ShareColumn.Styles)
        {
            style.Items.Add(new ComboBoxItem { Content = Strings.Get("MaskStyle_" + each), Tag = each });
        }

        style.SelectedItem = style.Items.OfType<ComboBoxItem>().FirstOrDefault(item => (MaskStyle)item.Tag == column.Style);
        AutomationProperties.SetName(style, Strings.Format("ShareColumnStyleName", column.Name));
        action.SelectionChanged += (_, _) =>
        {
            if (action.SelectedItem is ComboBoxItem { Tag: ShareColumnAction picked } && picked != column.Action)
            {
                column.Choose(picked);
                style.Visibility = picked == ShareColumnAction.Mask ? Visibility.Visible : Visibility.Collapsed;
                ColumnsChanged();
            }
        };
        style.SelectionChanged += (_, _) =>
        {
            if (style.SelectedItem is ComboBoxItem { Tag: MaskStyle picked } && picked != column.Style)
            {
                column.Choose(picked);
                ColumnsChanged();
            }
        };
        row.Children.Add(label);
        Grid.SetColumn(action, 1);
        row.Children.Add(action);
        Grid.SetColumn(style, 2);
        row.Children.Add(style);
        return row;
    }

    private static string? Reason(ShareColumn column)
    {
        if (column.Suggestion is not { } suggestion)
        {
            return null;
        }

        var looks = SensitiveWords.KeyFor(suggestion.Reason) is { } key
            ? Strings.Get(key)
            : (suggestion.Reason as MaskReason.ColumnName)?.Term ?? string.Empty;
        return Strings.Format("ShareColumnLooksLike", looks);
    }

    // The counts, the notes, the warnings, the preview and Share follow every choice.
    private void ColumnsChanged()
    {
        if (_rounds.Plan is null)
        {
            return;
        }

        var columns = _columns;
        _columnsSection.Visibility = columns is { Columns.Count: > 0 } ? Visibility.Visible : Visibility.Collapsed;
        ShowColumnsSummary(columns is null ? string.Empty : Strings.Format(columns.SummaryKey, columns.Masked, columns.Removed));
        _detectionNote.Visibility = columns is { HasDetections: true } ? Visibility.Visible : Visibility.Collapsed;
        var noColumns = columns is { RemovesEveryColumn: true };
        _noColumns.IsOpen = noColumns;
        _noColumns.Visibility = noColumns ? Visibility.Visible : Visibility.Collapsed;
        ShowSecrets();
        _ = RefreshSummaryAsync();
    }

    // A TextBlock that changes text is not read out by itself, so its live region is raised.
    private void ShowColumnsSummary(string text)
    {
        if (string.Equals(_columnsSummary.Text, text, StringComparison.Ordinal))
        {
            return;
        }

        _columnsSummary.Text = text;
        if (text.Length > 0 && AutomationPeer.ListenerExists(AutomationEvents.LiveRegionChanged))
        {
            FrameworkElementAutomationPeer.CreatePeerForElement(_columnsSummary)
                .RaiseAutomationEvent(AutomationEvents.LiveRegionChanged);
        }
    }

    // A result is shared only once this round's columns, summary and preview are in, so a detected column never
    // leaves unmasked by a quick click, a result too large never reaches the server, and the preview shows what goes.
    private void UpdateShareButton() =>
        _dialog.IsPrimaryButtonEnabled = !_creating && !_created && _rounds.CanShare(_columns)
            && FieldProblems().Count == 0;

    private IReadOnlyList<string> FieldProblems() =>
        _rounds.Plan?.FieldProblems(_password.Password, _content.Sql) ?? [];

    // As macOS: a field the core would refuse says why under the password, and Share stays off until it is fixed.
    private void ShowFieldProblems()
    {
        var problems = FieldProblems();
        var shown = problems.Count > 0;
        _fieldProblems.Message = string.Join("\n", problems.Select(Strings.Get));
        if (shown != _fieldProblems.IsOpen)
        {
            // Narrator reads an InfoBar when it opens.
            _fieldProblems.IsOpen = shown;
        }

        _fieldProblems.Visibility = shown ? Visibility.Visible : Visibility.Collapsed;
        UpdateShareButton();
    }

    // Read again for each choice, off the UI thread; an older read that lands late is dropped, so Share waits.
    private async Task RefreshSummaryAsync()
    {
        if (_rounds.Plan is not { } plan || _content.Rows is not { } rows || _columns is not { } columns)
        {
            UpdateShareButton();
            return;
        }

        var round = _rounds.Begin();
        UpdateShareButton();
        if (columns.RemovesEveryColumn)
        {
            ShowSummary(plan, null);
            return;
        }

        ShareSummary summary;
        try
        {
            summary = await rows.GetShareSummaryAsync(_content.Columns.Count, plan.Limits.MaxRows, columns.Choices)
                .ConfigureAwait(true);
        }
        catch (TableProException exception)
        {
            if (!_closed && _rounds.IsCurrent(round))
            {
                ShowError(Strings.Error(exception.Error));
            }

            return;
        }
        catch (ObjectDisposedException)
        {
            if (!_closed)
            {
                ShowError(Strings.Get("ShareRowsGone"));
            }

            return;
        }

        if (_closed || !ReferenceEquals(_rounds.Plan, plan) || !_rounds.TakeSummary(round, summary))
        {
            return;
        }

        ShowSummary(plan, summary);
        UpdateShareButton();
        if (summary.Refused is null)
        {
            await RefreshPreviewAsync(round, summary).ConfigureAwait(true);
        }
    }

    // The notes say what the core will send: the rows the body budget keeps, the column cap, or why nothing can go.
    private void ShowSummary(SharePlan plan, ShareSummary? summary)
    {
        var cut = summary is not null && plan.CutsRows(summary);
        _capNote.Text = cut ? Strings.Format("ShareCapNote", summary!.RowsSent, plan.TotalRows) : string.Empty;
        _capNote.Visibility = cut ? Visibility.Visible : Visibility.Collapsed;
        _columnsNote.Text = summary is null ? string.Empty : Strings.Format("ShareColumnsNote", summary.ColumnsSent);
        _columnsNote.Visibility = summary is { ColumnsTruncated: true } ? Visibility.Visible : Visibility.Collapsed;
        var tooLarge = summary?.Refused switch
        {
            ShareRefusal.Cell cell => Strings.Format("ShareTooLargeCell", cell.Column),
            ShareRefusal.FirstRow => Strings.Get("ShareTooLargeFirstRow"),
            _ => null,
        };
        var noColumns = _columns is { RemovesEveryColumn: true } || summary?.Refused is ShareRefusal.NoColumns;
        _noColumns.IsOpen = noColumns;
        _noColumns.Visibility = noColumns ? Visibility.Visible : Visibility.Collapsed;
        _tooLarge.Message = tooLarge ?? string.Empty;
        _tooLarge.IsOpen = tooLarge is not null;
        _tooLarge.Visibility = tooLarge is null ? Visibility.Collapsed : Visibility.Visible;
        if (_previewGrid is { } grid)
        {
            grid.Visibility = summary is { Refused: null } ? Visibility.Visible : Visibility.Collapsed;
        }
    }

    // The core masks and cuts the preview as the link will be, so a Stable Hash shows as it will be sent. Only the
    // current round's preview is shown; one that fails clears the grid, so it never shows older choices' values.
    private async Task RefreshPreviewAsync(int round, ShareSummary summary)
    {
        if (_previewGrid is not { } grid || _content.Rows is not { } rows
            || _columns is not { RemovesEveryColumn: false } columns)
        {
            return;
        }

        var count = SharePlan.PreviewRowsOf(summary);
        ResultSet preview;
        try
        {
            preview = await rows.GetSharePreviewAsync(_content.Columns.Count, count, columns.Choices).ConfigureAwait(true);
        }
        catch (Exception exception) when (exception is TableProException or ObjectDisposedException)
        {
            if (!_closed && _rounds.IsCurrent(round))
            {
                ShowPreview(null, 0);
                ShowError(exception is TableProException failed ? Strings.Error(failed.Error) : Strings.Get("ShareRowsGone"));
            }

            return;
        }

        if (_closed || !_rounds.TakePreview(round))
        {
            preview.Dispose();
            return;
        }

        ShowPreview(preview, count);
        UpdateShareButton();
    }

    private void ShowPreview(ResultSet? preview, int count)
    {
        var previous = _previewRows;
        _previewRows = preview;
        if (_previewGrid is { } grid)
        {
            grid.Height = ((count + 1) * 32) + 2 + PreviewScrollBarRoom;
            // Before the data, so a column sized to its header leaves room for the mark.
            grid.SetMaskedColumns(preview is null || _columns is not { } columns
                ? []
                : [.. columns.SentStyles.Select(style => style is { } masked
                    ? Strings.Format("SharePreviewMasked", Strings.Get("MaskStyle_" + masked))
                    : null)]);
            grid.SetData(preview is null ? null : new ResultSetData(preview, preview.GetColumns()));
        }

        // The grid gave the old set's cursor back in SetData.
        previous?.Dispose();
    }

    // Warnings only: a share is never refused for them. Hidden SQL is not shown to anyone with the link.
    private void ShowSecrets()
    {
        var lines = new List<string>();
        var sqlShown = _subject.Kind == ShareKind.Query || _hideSql.IsChecked != true;
        if (sqlShown && _content.Sql.Length > 0)
        {
            var kinds = ShareLinks.ScanSql(_content.Sql)
                .Select(hit => hit.Kind)
                .Distinct()
                .Select(kind => Strings.Get("SecretKind_" + kind))
                .ToList();
            if (kinds.Count > 0)
            {
                lines.Add(Strings.Format("ShareSecretInSql", string.Join(CultureInfo.CurrentCulture.TextInfo.ListSeparator + " ", kinds)));
            }
        }

        if (_subject.Kind == ShareKind.Result)
        {
            // A masked or removed column sends no value that could be a secret.
            var shared = _rounds.Plan?.SharedColumns(_content.Columns.Count) ?? _content.Columns.Count;
            var names = _columns is { } chosen
                ? chosen.Columns.Where(column => column.Action == ShareColumnAction.Keep).Select(column => column.Name)
                : _content.Columns.Take(shared).Select(column => column.Name);
            var columns = ShareLinks.ScanColumns(names);
            if (columns.Count > 0)
            {
                lines.Add(Strings.Format("ShareSecretColumns", string.Join(CultureInfo.CurrentCulture.TextInfo.ListSeparator + " ", columns)));
            }
        }

        _secrets.Message = string.Join("\n", lines);
        _secrets.IsOpen = lines.Count > 0;
        _secrets.Visibility = lines.Count > 0 ? Visibility.Visible : Visibility.Collapsed;
        ShowHideSqlSuggestion();
    }

    // Only while Hide SQL is off and there is SQL to hide; the notice's button turns it on.
    private void ShowHideSqlSuggestion()
    {
        var kinds = _subject.Kind == ShareKind.Result && _rounds.Plan is { OffersHideSql: true } && _hideSql.IsChecked != true
            ? ShareLinks.ScanSqlForPersonalData(_content.Sql)
                .Select(hit => hit.Kind)
                .Distinct()
                .Select(kind => Strings.Get(SensitiveWords.KeyFor(kind)))
                .ToList()
            : [];
        var shown = kinds.Count > 0;
        _personalData.Message = shown
            ? Strings.Format("ShareHideSqlSuggestion", string.Join(CultureInfo.CurrentCulture.TextInfo.ListSeparator + " ", kinds))
            : string.Empty;
        if (shown != _personalData.IsOpen)
        {
            // Narrator reads an InfoBar when it opens.
            _personalData.IsOpen = shown;
        }

        _personalData.Visibility = shown ? Visibility.Visible : Visibility.Collapsed;
    }

    private async Task ShowAtCapAsync(TableProAccount account, SharePlan plan, int generation)
    {
        ShowBusy(Strings.Get("ShareLoading"));
        var links = new List<SharedLink>();
        string? cursor = null;
        for (var page = 0; page < MostListPages; page++)
        {
            var read = await account.ListSharesAsync(liveOnly: true, plan.TeamId, cursor).ConfigureAwait(true);
            links.AddRange(read.Shares);
            cursor = read.NextCursor;
            if (cursor is null)
            {
                break;
            }
        }

        if (generation != _generation || _closed)
        {
            return;
        }

        _atCap.Children.Clear();
        _atCap.Children.Add(new TextBlock
        {
            Text = plan.Cap switch
            {
                { Team: { } team } cap => Strings.Format("ShareAtCapTeam", team, cap.Live, cap.Limit),
                { Pro: true } cap => Strings.Format("ShareAtCapPro", cap.Live, cap.Limit),
                var cap => Strings.Format("ShareAtCapFree", cap.Live, cap.Limit),
            },
            TextWrapping = TextWrapping.Wrap,
        });
        if (!plan.Cap.Pro)
        {
            _atCap.Children.Add(new TextBlock { Text = Strings.Get("ShareAtCapProAllows"), TextWrapping = TextWrapping.Wrap });
        }

        foreach (var link in SharePlan.LiveOldestFirst(links, plan.TeamId))
        {
            _atCap.Children.Add(LinkRow(account, link));
        }

        Show(_atCap);
    }

    private Grid LinkRow(TableProAccount account, SharedLink link)
    {
        var row = new Grid { ColumnSpacing = 12 };
        row.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        row.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        var title = string.IsNullOrWhiteSpace(link.Title) ? Strings.Get("ShareUntitled") : link.Title;
        var text = new StackPanel();
        text.Children.Add(new TextBlock { Text = title, TextTrimming = TextTrimming.CharacterEllipsis });
        text.Children.Add(new TextBlock
        {
            Text = link.ExpiresAt is { } expires
                ? Strings.Format("ShareLinkCreatedExpires", link.CreatedAt.LocalDateTime, expires.LocalDateTime)
                : Strings.Format("ShareLinkCreated", link.CreatedAt.LocalDateTime),
            Style = Caption,
        });
        if (link.Suspended)
        {
            text.Children.Add(new TextBlock { Text = Strings.Get("ShareSuspended"), Style = Caption });
        }

        row.Children.Add(text);
        var revoke = new Button { Content = Strings.Get("ShareRevoke"), VerticalAlignment = VerticalAlignment.Center };
        AutomationProperties.SetName(revoke, Strings.Format("ShareRevokeName", title));
        revoke.Click += async (_, _) => await RevokeAsync(account, link, revoke).ConfigureAwait(true);
        Grid.SetColumn(revoke, 1);
        row.Children.Add(revoke);
        return row;
    }

    // A freed slot shows the form again, from limits read anew.
    private async Task RevokeAsync(TableProAccount account, SharedLink link, Button button)
    {
        button.IsEnabled = false;
        try
        {
            await account.RevokeShareAsync(link.Id).ConfigureAwait(true);
        }
        catch (TableProException exception)
        {
            if (!_closed)
            {
                button.IsEnabled = true;
                ShowNotice(InfoBarSeverity.Error, Strings.Error(exception.Error), (Strings.Get("ShareRetry"), () => _ = LoadAsync()));
            }

            return;
        }

        if (!_closed)
        {
            await LoadAsync().ConfigureAwait(true);
        }
    }

    // The dialog stays open to show the link; one create at a time.
    private async void OnShare(ContentDialog sender, ContentDialogButtonClickEventArgs args)
    {
        args.Cancel = true;
        if (_creating || _created || _rounds.Plan is not { } plan || !_rounds.CanShare(_columns)
            || FieldProblems().Count > 0)
        {
            return;
        }

        var choices = _columns?.Choices ?? [];

        _creating = true;
        _dialog.IsPrimaryButtonEnabled = false;
        _owners.IsEnabled = false;
        _error.IsOpen = false;
        _error.Visibility = Visibility.Collapsed;
        var form = new ShareForm(
            _title.Text,
            _note.Text,
            (_expires.SelectedItem as ComboBoxItem)?.Tag as ShareExpiry? ?? plan.DefaultExpiry,
            _hideSql.IsChecked == true,
            _password.Password,
            _allowDownload.IsChecked != false);
        var content = _content;
        var request = plan.Request(form, content.Sql, _subject.Dialect);
        ShowBusy(Strings.Get("ShareCreating"), keep: _form);
        try
        {
            var account = await _workbench.GetAccountAsync().ConfigureAwait(true)
                ?? throw new TableProException(new CoreError("account.signed_out", ["account.signed_out"], string.Empty, null, null));
            var created = await account.CreateShareAsync(
                    request, content.Rows, content.Columns.Count, plan.Limits.MaxRows, content.ViewCount, choices)
                .ConfigureAwait(true);
            _created = true;
            // The link exists, so it is copied even when the sheet closed while it was made.
            WorkspaceView.CopyText(created.Url);
            if (!_closed)
            {
                ShowCreated(created);
            }
        }
        catch (TableProException exception)
        {
            if (_closed)
            {
                return;
            }

            if (ShareErrors.ReloadsLimits(exception.Code) || exception.Code == "account.signed_out")
            {
                _creating = false;
                await LoadAsync().ConfigureAwait(true);
                return;
            }

            ShowError(Strings.Get(ShareErrors.KeyFor(exception.Code)));
        }
        catch (ObjectDisposedException)
        {
            if (!_closed)
            {
                ShowError(Strings.Get("ShareRowsGone"));
            }
        }
        finally
        {
            _creating = false;
            _owners.IsEnabled = true;
            if (!_created && !_closed)
            {
                _busy.Visibility = Visibility.Collapsed;
                UpdateShareButton();
            }
        }
    }

    private void ShowCreated(CreatedShare created)
    {
        _url.Text = created.Url;
        if (created.ColumnsTruncated && _rounds.Plan is { } plan)
        {
            _doneNote.Text = Strings.Format("ShareColumnsCut", plan.Limits.MaxColumns);
            _doneNote.Visibility = Visibility.Visible;
        }

        _dialog.PrimaryButtonText = string.Empty;
        _dialog.CloseButtonText = Strings.Get("ShareDone");
        _dialog.DefaultButton = ContentDialogButton.Close;
        Show(_done);
    }

    private void ShowError(string message)
    {
        _error.Message = message;
        _error.Visibility = Visibility.Visible;
        // Narrator reads an InfoBar when it opens, not when its text changes.
        _error.IsOpen = false;
        _error.IsOpen = true;
    }

    private void ShowBusy(string text, string? actionText = null, Action? action = null, UIElement? keep = null)
    {
        _busyText.Text = text;
        while (_busy.Children.Count > 2)
        {
            _busy.Children.RemoveAt(2);
        }

        if (actionText is not null && action is not null)
        {
            var button = new Button { Content = actionText };
            AutomationProperties.SetAutomationId(button, "ShareBusyAction");
            button.Click += (_, _) => action();
            _busy.Children.Add(button);
        }

        Show(keep);
        _busy.Visibility = Visibility.Visible;
    }

    private void ShowNotice(
        InfoBarSeverity severity, string message, (string Text, Action Invoke)? action, string? automationId = null)
    {
        _notice.Severity = severity;
        _notice.Message = message;
        if (action is { } act)
        {
            var button = new Button { Content = act.Text };
            AutomationProperties.SetAutomationId(button, automationId ?? "ShareNoticeAction");
            button.Click += (_, _) => act.Invoke();
            _notice.ActionButton = button;
        }
        else
        {
            _notice.ActionButton = null;
        }

        Show(_notice);
        _notice.IsOpen = false;
        _notice.IsOpen = true;
    }

    // One section at a time, with the footer whenever the limits were read.
    private void Show(UIElement? section)
    {
        foreach (var part in new UIElement[] { _busy, _notice, _form, _atCap, _done })
        {
            part.Visibility = ReferenceEquals(part, section) ? Visibility.Visible : Visibility.Collapsed;
        }

        _footer.Visibility = _footer.Text.Length > 0 && !ReferenceEquals(section, _done)
            ? Visibility.Visible
            : Visibility.Collapsed;
        var choosing = ReferenceEquals(section, _form) || ReferenceEquals(section, _atCap);
        _owners.Visibility = choosing && _owners.Items.Count > 1 ? Visibility.Visible : Visibility.Collapsed;
    }

    private static async Task OpenAsync(string url)
    {
        if (Uri.TryCreate(url, UriKind.Absolute, out var uri))
        {
            await Launcher.LaunchUriAsync(uri);
        }
    }

}
