using System.Globalization;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
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
    Func<long, Task<TableShareRead>>? ReadTable = null)
{
    public long TotalRows => Rows?.RowCount ?? 0;

    public static ShareSubject Query(string sql, string title, string? dialect) =>
        new(ShareKind.Query, sql, title, dialect, null, []);

    public static ShareSubject Result(
        string sql, string title, string? dialect, ResultSet rows, IReadOnlyList<ResultColumn> columns) =>
        new(ShareKind.Result, sql, title, dialect, rows, columns);

    // The view is read from its first row up to the plan's rows, so the sheet reads it after the limits.
    public static ShareSubject Table(string title, string? dialect, Func<long, Task<TableShareRead>> read) =>
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
    private readonly InfoBar _secrets = new() { IsClosable = false, Severity = InfoBarSeverity.Warning };
    private readonly InfoBar _error = new() { IsClosable = true, Severity = InfoBarSeverity.Error };
    private readonly StackPanel _atCap = new() { Spacing = 12 };
    private readonly StackPanel _done = new() { Spacing = 12 };
    private readonly TextBox _url = new() { IsReadOnly = true };
    private readonly TextBlock _footer = new();
    private DataGridView? _previewGrid;
    private SharedContent _content;
    private TableShareRead? _tableRead;
    private long _tableReadFor = -1;
    private SharePlan? _plan;
    private AccountStage _stage;
    private int _generation;
    private bool _creating;
    private bool _created;
    private bool _closed;

    private ShareSheet(FrameworkElement owner, Workbench workbench, ShareSubject subject)
    {
        _workbench = workbench;
        _subject = subject;
        _content = new SharedContent(subject.Sql, subject.Rows, subject.Columns, subject.TotalRows, null);
        _dialog = new ContentDialog
        {
            RequestedTheme = owner.ActualTheme,
            Title = Strings.Get(subject.Kind == ShareKind.Result ? "ShareResultTitle" : "ShareQueryTitle"),
            Content = Layout(),
            PrimaryButtonText = Strings.Get("ShareAction"),
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

        var sheet = new ShareSheet(owner, workbench, subject);
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
            workbench.AccountChanged -= sheet.OnAccountChanged;
            // The grid gives its cursor back here, before the result set can go.
            sheet._previewGrid?.SetData(null);
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

        _form.Children.Add(_title);
        _form.Children.Add(_note);
        _form.Children.Add(WithTag(_expires, _expiresPro));
        if (_subject.Kind == ShareKind.Result)
        {
            _form.Children.Add(_hideSql);
            _noSql.Text = Strings.Get("ShareTableNoSql");
            AutomationProperties.SetAutomationId(_noSql, "ShareTableNoSql");
            _form.Children.Add(_noSql);
        }

        _form.Children.Add(WithTag(_password, _passwordPro));
        _form.Children.Add(WithTag(_allowDownload, _downloadPro));
        if (_subject.Kind == ShareKind.Result)
        {
            _preview.Children.Add(new TextBlock
            {
                Text = Strings.Get("SharePreviewHeader"),
                Style = (Style)Application.Current.Resources["BodyStrongTextBlockStyle"],
            });
            _previewGrid = new DataGridView { SizeColumnsToContent = true };
            AutomationProperties.SetName(_previewGrid, Strings.Get("SharePreviewHeader"));
            AutomationProperties.SetAutomationId(_previewGrid, "SharePreview");
            _preview.Children.Add(_previewGrid);
            _preview.Children.Add(_capNote);
            _form.Children.Add(_preview);
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

        _footer.Style = Caption;
        AutomationProperties.SetAutomationId(_footer, "ShareFooter");

        var root = new StackPanel { Spacing = 12, MinWidth = 400 };
        AutomationProperties.SetAutomationId(root, "ShareSheet");
        foreach (var part in new UIElement[] { _busy, _notice, _form, _atCap, _done, _footer })
        {
            part.Visibility = Visibility.Collapsed;
            root.Children.Add(part);
        }

        return new ScrollViewer { Content = root, MaxHeight = 560 };
    }

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
        _plan = null;
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
        var plan = SharePlan.For(limits, _subject.Kind, _content.TotalRows, _content.Sql.Length > 0);
        _footer.Text = plan.Footer.Pro
            ? Strings.Format("ShareFooterPro", plan.Footer.Live)
            : Strings.Format("ShareFooterFree", plan.Footer.Live, plan.Footer.Limit, plan.Footer.MaxRows);
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

                    plan = SharePlan.For(limits, _subject.Kind, _content.TotalRows, _content.Sql.Length > 0);
                }

                ShowForm(plan);
                break;
        }
    }

    // The preview and the link both take these rows, so they are read once per plan.
    private async Task ReadTableAsync(Func<long, Task<TableShareRead>> read, long maxRows)
    {
        ShowBusy(Strings.Get("ShareReadingRows"));
        var table = await read(maxRows).ConfigureAwait(true);
        if (_closed)
        {
            table.Dispose();
            return;
        }

        _previewGrid?.SetData(null);
        _tableRead?.Dispose();
        _tableRead = table;
        _tableReadFor = maxRows;
        var columns = table.Rows?.GetColumns().Take(table.VisibleColumns).ToList() ?? [];
        _content = new SharedContent(table.ViewSql ?? string.Empty, table.Rows, columns, table.TotalRows, table.TotalRows);
        _noSql.Visibility = table.ViewSql is null ? Visibility.Visible : Visibility.Collapsed;
    }

    private void ShowForm(SharePlan plan)
    {
        _plan = plan;
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

        if (_content.Rows is { } rows && _previewGrid is { Data: null } grid)
        {
            var count = (int)plan.PreviewRowCount;
            grid.Height = (count + 1) * 32 + 2;
            grid.SetData(new FirstRows(new ResultSetData(rows, _content.Columns), count));
        }

        _capNote.Text = plan.IsTruncated
            ? Strings.Format("ShareCapNote", plan.SharedRows, plan.TotalRows)
            : string.Empty;
        _capNote.Visibility = plan.IsTruncated ? Visibility.Visible : Visibility.Collapsed;
        ShowSecrets();
        Show(_form);
        _dialog.IsPrimaryButtonEnabled = true;
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
            var columns = ShareLinks.ScanColumns(_content.Columns.Select(column => column.Name));
            if (columns.Count > 0)
            {
                lines.Add(Strings.Format("ShareSecretColumns", string.Join(CultureInfo.CurrentCulture.TextInfo.ListSeparator + " ", columns)));
            }
        }

        _secrets.Message = string.Join("\n", lines);
        _secrets.IsOpen = lines.Count > 0;
        _secrets.Visibility = lines.Count > 0 ? Visibility.Visible : Visibility.Collapsed;
    }

    private async Task ShowAtCapAsync(TableProAccount account, SharePlan plan, int generation)
    {
        ShowBusy(Strings.Get("ShareLoading"));
        var links = new List<SharedLink>();
        string? cursor = null;
        for (var page = 0; page < MostListPages; page++)
        {
            var read = await account.ListSharesAsync(liveOnly: true, cursor).ConfigureAwait(true);
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
            Text = Strings.Format(plan.IsPro ? "ShareAtCapPro" : "ShareAtCapFree", plan.Limits.LiveLimit),
            TextWrapping = TextWrapping.Wrap,
        });
        if (!plan.IsPro)
        {
            _atCap.Children.Add(new TextBlock { Text = Strings.Get("ShareAtCapProAllows"), TextWrapping = TextWrapping.Wrap });
        }

        foreach (var link in SharePlan.LiveOldestFirst(links))
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
            text.Children.Add(new TextBlock { Text = Strings.Get("ShareLinkSuspended"), Style = Caption });
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
        if (_creating || _created || _plan is not { Stage: ShareStage.Form } plan)
        {
            return;
        }

        _creating = true;
        _dialog.IsPrimaryButtonEnabled = false;
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
                    request, content.Rows, content.Columns.Count, plan.Limits.MaxRows, content.ViewCount)
                .ConfigureAwait(true);
            _created = true;
            // The link exists, so it is copied even when the sheet closed while it was made.
            WorkspaceView.CopyText(created.Url);
            if (!_closed)
            {
                ShowCreated(created.Url);
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
            if (!_created && !_closed)
            {
                _busy.Visibility = Visibility.Collapsed;
                _dialog.IsPrimaryButtonEnabled = _plan is { Stage: ShareStage.Form };
            }
        }
    }

    private void ShowCreated(string url)
    {
        _url.Text = url;
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
    }

    private static async Task OpenAsync(string url)
    {
        if (Uri.TryCreate(url, UriKind.Absolute, out var uri))
        {
            await Launcher.LaunchUriAsync(uri);
        }
    }

    // The preview reads the result's own cells, only its first rows.
    private sealed class FirstRows(IGridData rows, int count) : IGridData
    {
        public int RowCount => Math.Min(rows.RowCount, count);

        public int ColumnCount => rows.ColumnCount;

        public string GetColumnName(int column) => rows.GetColumnName(column);

        public IGridReader OpenReader() => rows.OpenReader();
    }
}
