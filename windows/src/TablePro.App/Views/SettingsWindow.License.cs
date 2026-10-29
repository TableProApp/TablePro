using System.Globalization;
using Microsoft.UI.Text;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Media;
using TablePro.App.Services;
using TablePro.Core.Licensing;
using TablePro.Storage.Licensing;
using Windows.ApplicationModel.DataTransfer;

namespace TablePro.App.Views;

public sealed partial class SettingsWindow
{
    private const string LicensePage = "License";

    /// <summary>
    /// The License page, as macOS lays out its License pane: what you hold, whether it works, the seats it covers and
    /// the team on it. The layout is keyed on holding a license; entitlement decides only whether a renewal field
    /// shows, because a lapsed license still has seats to release and an account to manage.
    /// </summary>
    private void BuildLicensePage(StackPanel page)
    {
        if (_host.Licensing is not { } license)
        {
            return;
        }

        var body = new StackPanel { Spacing = 4 };
        var form = new LicenseActivationForm(license);
        var queued = 0;
        void Render()
        {
            Interlocked.Exchange(ref queued, 0);
            body.Children.Clear();
            RenderLicense(body, license, form);
        }

        // The service announces every step of a check from whichever thread ran it; one render per burst is enough.
        void OnChanged(object? sender, EventArgs e)
        {
            if (Interlocked.Exchange(ref queued, 1) == 0)
            {
                DispatcherQueue.TryEnqueue(Render);
            }
        }

        license.Changed += OnChanged;
        body.Unloaded += (_, _) => license.Changed -= OnChanged;
        Closed += (_, _) => license.Changed -= OnChanged;
        Render();
        page.Children.Add(body);
        _ = license.LoadDevicesAsync();
        _ = license.LoadTeamAsync();
    }

    private void RenderLicense(StackPanel body, LicenseService license, LicenseActivationForm form)
    {
        var held = license.License;
        var status = license.Status;
        var now = DateTimeOffset.UtcNow;
        if (LicensePresentation.Notice(status, held?.DaysUntilExpiry(now), held?.IsExpired(now) ?? false, held is not null) is { } notice)
        {
            body.Children.Add(NoticeBar(notice, license));
        }

        form.Detach();
        var groups = LicensePresentation.FeatureGroups(status, license.CurrentTier);
        if (held is null)
        {
            body.Children.Add(LandingCard(license, form));
            AddFeatureGroups(body, groups, offersPurchase: true);
            return;
        }

        body.Children.Add(IdentityCard(license, held, status));
        if (LicensePresentation.ShowsRenewalField(status))
        {
            body.Children.Add(CardOf(form.Root));
        }

        body.Children.Add(Card(Strings.Get("License/LicenseKey"), null, KeyRow(held.Key)));
        AddDevices(body, license, held);
        if (license.ShowsTeamRoster)
        {
            AddTeam(body, license, held);
        }

        AddFeatureGroups(body, groups, offersPurchase: false);
        body.Children.Add(ActionsCard(license));
    }

    private static InfoBar NoticeBar(LicenseNotice notice, LicenseService license)
    {
        var (title, message) = LicenseNames.Notice(notice);
        var bar = new InfoBar
        {
            IsOpen = true,
            IsClosable = false,
            Title = title,
            Message = message,
            Severity = notice.Tone switch
            {
                LicenseNoticeTone.Critical => InfoBarSeverity.Error,
                LicenseNoticeTone.Warning => InfoBarSeverity.Warning,
                _ => InfoBarSeverity.Informational,
            },
            Margin = new Thickness(0, 0, 0, 8),
        };
        switch (notice.Action)
        {
            case LicenseNoticeAction.Renew:
                bar.ActionButton = Link(Strings.Get("License/RenewLicense"), SupportLinks.Pricing(SupportReferrer.LicenseSettings));
                break;
            case LicenseNoticeAction.Purchase:
                bar.ActionButton = Link(Strings.Get("License/BuyLicense"), SupportLinks.Pricing(SupportReferrer.LicenseSettings));
                break;
            case LicenseNoticeAction.RetryValidation:
                var retry = new Button { Content = Strings.Get("License/TryAgain"), IsEnabled = !license.IsValidating };
                retry.Click += async (_, _) => await license.RevalidateAsync();
                bar.ActionButton = retry;
                break;
        }

        return bar;
    }

    /// <summary>The way in for somebody without a license: the pitch, the field, and why a seat given up may still count.</summary>
    private static Border LandingCard(LicenseService license, LicenseActivationForm form)
    {
        var content = new StackPanel { Spacing = 6 };
        content.Children.Add(new TextBlock { Text = Strings.Get("License/LandingTitle"), Style = (Style)Application.Current.Resources["BodyStrongTextBlockStyle"] });
        content.Children.Add(Secondary(Strings.Get("License/LandingMessage")));
        if (license.ReleaseError is { } releaseError)
        {
            content.Children.Add(Caution(LicenseNames.Error(releaseError)));
        }

        form.Root.Margin = new Thickness(0, 8, 0, 0);
        content.Children.Add(form.Root);
        return CardOf(content);
    }

    /// <summary>Who the license is for and what it is, with Refresh, which checks the license and reloads its seats.</summary>
    private static Border IdentityCard(LicenseService license, License held, LicenseStatus status)
    {
        // A seal that stays green on a license that is not working would be the page telling a comfortable lie.
        var entitled = LicensePresentation.ShowsLicensedLayout(status);
        var seal = new FontIcon
        {
            Glyph = entitled ? "\xEC61" : "\xEB95",
            FontSize = 32,
            Foreground = (Brush)Application.Current.Resources[entitled ? "SystemFillColorSuccessBrush" : "TextFillColorSecondaryBrush"],
            VerticalAlignment = VerticalAlignment.Center,
        };
        AutomationProperties.SetAccessibilityView(seal, Microsoft.UI.Xaml.Automation.Peers.AccessibilityView.Raw);

        var text = new StackPanel { Spacing = 2, VerticalAlignment = VerticalAlignment.Center };
        text.Children.Add(new TextBlock { Text = held.Email, Style = (Style)Application.Current.Resources["BodyStrongTextBlockStyle"], TextTrimming = TextTrimming.CharacterEllipsis });
        text.Children.Add(Secondary(LicenseNames.PlanDescription(held)));

        var busy = license.IsValidating || license.IsRefreshingDevices;
        var refresh = new Button { Content = Strings.Get("Common/Refresh"), IsEnabled = !busy, VerticalAlignment = VerticalAlignment.Center };
        refresh.Click += async (_, _) => await license.RefreshAsync();

        var grid = new Grid { ColumnSpacing = 16 };
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        grid.Children.Add(seal);
        Grid.SetColumn(text, 1);
        grid.Children.Add(text);
        if (busy)
        {
            var ring = new ProgressRing { IsActive = true, Width = 16, Height = 16 };
            Grid.SetColumn(ring, 2);
            grid.Children.Add(ring);
        }

        Grid.SetColumn(refresh, 3);
        grid.Children.Add(refresh);
        return CardOf(grid);
    }

    /// <summary>
    /// The first group of the key and Copy for the whole of it. A key is a bearer credential, so it is never on screen
    /// in full, and the copy stays out of clipboard history and off other devices.
    /// </summary>
    private static StackPanel KeyRow(string key)
    {
        var masked = new TextBlock { Text = LicensePresentation.MaskedKey(key), FontFamily = new FontFamily("Consolas"), VerticalAlignment = VerticalAlignment.Center };
        AutomationProperties.SetName(masked, Strings.Get("License/LicenseKeyHidden"));
        var copy = new Button { Content = Strings.Get("License/CopyKey") };
        copy.Click += (_, _) =>
        {
            var package = new DataPackage();
            package.SetText(key);
            Clipboard.SetContentWithOptions(package, new ClipboardContentOptions { IsAllowedInHistory = false, IsRoamable = false });
        };
        var row = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 12 };
        row.Children.Add(masked);
        row.Children.Add(copy);
        return row;
    }

    /// <summary>
    /// The machines the license is activated on. This PC's own seat goes through Deactivate below, so the list releases
    /// only other machines, and only on a license nobody else shares.
    /// </summary>
    private void AddDevices(StackPanel body, LicenseService license, License held)
    {
        var state = license.DeviceListState;
        var devices = license.Devices;
        var trailing = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 8 };
        if (license.IsRefreshingDevices)
        {
            trailing.Children.Add(new ProgressRing { IsActive = true, Width = 16, Height = 16 });
        }

        if (state == LicenseListState.Loaded)
        {
            trailing.Children.Add(Secondary(Strings.Format("License/DeviceCount", devices.Count, license.MaxDevices)));
        }

        body.Children.Add(SectionHeader(Strings.Get("License/DevicesHeader"), trailing));

        var content = new StackPanel { Spacing = 8 };
        switch (state)
        {
            case LicenseListState.Idle or LicenseListState.Loading:
                content.Children.Add(Loading(Strings.Get("License/LoadingDevices")));
                break;
            case LicenseListState.Failed:
                content.Children.Add(Caution(LicenseNames.Error(license.DeviceListError!)));
                content.Children.Add(RetryButton(() => license.LoadDevicesAsync(force: true)));
                break;
            default:
                if (devices.Count == 0)
                {
                    content.Children.Add(Secondary(Strings.Get("License/NoDevices")));
                }

                foreach (var device in devices)
                {
                    content.Children.Add(DeviceRow(license, device));
                }

                break;
        }

        if ((license.ReleaseError ?? license.RefreshError) is { } problem && state != LicenseListState.Failed)
        {
            content.Children.Add(Caution(LicenseNames.Error(problem)));
        }

        body.Children.Add(CardOf(content));
        if (held.IsTeamLicense)
        {
            body.Children.Add(Secondary(Strings.Get("License/TeamSeatsFooter")));
        }
    }

    private Grid DeviceRow(LicenseService license, LicenseActivation device)
    {
        var isThisPc = device.MachineId == license.MachineId;
        var icon = new FontIcon { Glyph = "\xE7F4", Foreground = (Brush)Application.Current.Resources["TextFillColorSecondaryBrush"], VerticalAlignment = VerticalAlignment.Center };
        AutomationProperties.SetAccessibilityView(icon, Microsoft.UI.Xaml.Automation.Peers.AccessibilityView.Raw);

        // Last use is what decides which seat to release, so another machine shows it where this one says This PC.
        var secondary = new List<string>();
        if (isThisPc)
        {
            secondary.Add(Strings.Get("License/ThisDevice"));
        }
        else if (License.ParseInternetDate(device.LastValidatedAt) is { } lastUsed)
        {
            secondary.Add(Strings.Format("License/LastUsed", lastUsed.ToLocalTime().ToString("d", CultureInfo.CurrentCulture)));
        }

        secondary.Add(device.OsVersion);
        var text = new StackPanel { Spacing = 2, VerticalAlignment = VerticalAlignment.Center };
        text.Children.Add(new TextBlock { Text = device.MachineName, FontWeight = isThisPc ? FontWeights.SemiBold : FontWeights.Normal, TextTrimming = TextTrimming.CharacterEllipsis });
        text.Children.Add(Secondary(string.Join(", ", secondary)));

        var row = new Grid { ColumnSpacing = 12 };
        row.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        row.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        row.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        row.Children.Add(icon);
        Grid.SetColumn(text, 1);
        row.Children.Add(text);

        FrameworkElement? action = null;
        if (license.IsReleasing(device.MachineId))
        {
            action = new ProgressRing { IsActive = true, Width = 16, Height = 16 };
        }
        else if (!isThisPc && license.CanReleaseOtherDevices)
        {
            var release = new Button { Content = Strings.Get("License/ReleaseButton") };
            AutomationProperties.SetName(release, Strings.Format("License/ReleaseAutomation", device.MachineName));
            release.Click += async (_, _) =>
            {
                if (await new DialogService(this).ConfirmAsync(Strings.Format("License/ReleaseTitle", device.MachineName), Strings.Get("License/ReleaseMessage"), Strings.Get("License/Release"), destructive: true))
                {
                    await license.ReleaseDeviceAsync(device);
                }
            };
            action = release;
        }

        if (action is not null)
        {
            action.VerticalAlignment = VerticalAlignment.Center;
            Grid.SetColumn(action, 2);
            row.Children.Add(action);
        }

        return row;
    }

    /// <summary>Who is on a Team license, read only: invites and removals happen on tablepro.app.</summary>
    private static void AddTeam(StackPanel body, LicenseService license, License held)
    {
        var team = license.Team;
        var state = license.TeamListState;
        var trailing = new StackPanel { Orientation = Orientation.Horizontal };
        if (team is not null && state == LicenseListState.Loaded)
        {
            trailing.Children.Add(Secondary(Strings.Format("License/MemberCount", team.SeatsUsed, team.MaxSeats)));
        }

        body.Children.Add(SectionHeader(Strings.Get("License/TeamHeader"), trailing));
        var content = new StackPanel { Spacing = 8 };
        switch (state)
        {
            case LicenseListState.Idle or LicenseListState.Loading:
                content.Children.Add(Loading(Strings.Get("License/LoadingTeam")));
                break;
            case LicenseListState.Failed:
                content.Children.Add(Caution(LicenseNames.Error(license.TeamListError!)));
                content.Children.Add(RetryButton(() => license.LoadTeamAsync(force: true)));
                break;
            default:
                if (team is null || team.Members.Count == 0)
                {
                    content.Children.Add(Secondary(Strings.Get("License/NoMembers")));
                    break;
                }

                foreach (var member in team.Members)
                {
                    // The signed payload carries the license owner's email for every member, so this marks the owner
                    // rather than claiming to know which row is the reader.
                    var isOwner = string.Equals(member.Email, held.Email, StringComparison.OrdinalIgnoreCase);
                    var role = LicenseNames.Role(TeamRole.Parse(member.Role));
                    var row = new Grid { ColumnSpacing = 12 };
                    row.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
                    row.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
                    row.Children.Add(new TextBlock { Text = member.Email, FontWeight = isOwner ? FontWeights.SemiBold : FontWeights.Normal, TextTrimming = TextTrimming.CharacterEllipsis });
                    var roleText = Secondary(isOwner ? Strings.Format("License/RoleYou", role) : role);
                    Grid.SetColumn(roleText, 1);
                    row.Children.Add(roleText);
                    content.Children.Add(row);
                }

                break;
        }

        body.Children.Add(CardOf(content));
    }

    /// <summary>Each plan's features, lowest plan first, marked Included or offering an upgrade for the current license.</summary>
    private static void AddFeatureGroups(StackPanel body, IReadOnlyList<LicenseFeatureGroup> groups, bool offersPurchase)
    {
        foreach (var group in groups)
        {
            var heading = new StackPanel { Spacing = 2 };
            heading.Children.Add(new TextBlock { Text = Strings.Format("License/PlanTitle", LicenseNames.Tier(group.Tier)), Style = (Style)Application.Current.Resources["BodyStrongTextBlockStyle"] });
            if (group.IncludedTier is { } included)
            {
                heading.Children.Add(Secondary(Strings.Format("License/IncludesEverything", LicenseNames.Tier(included))));
            }

            FrameworkElement access = group.Access.Kind switch
            {
                ProFeatureAccessKind.Available => IncludedLabel(),
                ProFeatureAccessKind.RequiresUpgrade => Link(Strings.Get("License/UpgradePlan"), SupportLinks.Pricing(SupportReferrer.LicenseSettings)),
                _ => new StackPanel(),
            };
            var header = new Grid { Margin = new Thickness(0, 20, 0, 4) };
            header.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
            header.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
            header.Children.Add(heading);
            access.VerticalAlignment = VerticalAlignment.Bottom;
            Grid.SetColumn(access, 1);
            header.Children.Add(access);
            body.Children.Add(header);

            var rows = new StackPanel { Spacing = 12 };
            foreach (var feature in group.Features)
            {
                var icon = new FontIcon { Glyph = LicenseNames.FeatureGlyph(feature), Width = 20, Foreground = (Brush)Application.Current.Resources["TextFillColorSecondaryBrush"], VerticalAlignment = VerticalAlignment.Top, Margin = new Thickness(0, 2, 0, 0) };
                AutomationProperties.SetAccessibilityView(icon, Microsoft.UI.Xaml.Automation.Peers.AccessibilityView.Raw);
                var text = new StackPanel { Spacing = 2 };
                text.Children.Add(new TextBlock { Text = LicenseNames.Feature(feature) });
                text.Children.Add(Secondary(LicenseNames.FeatureDescription(feature)));
                var row = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 12 };
                row.Children.Add(icon);
                row.Children.Add(text);
                rows.Children.Add(row);
            }

            body.Children.Add(CardOf(rows));
        }

        var links = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 8, Margin = new Thickness(0, 4, 0, 0) };
        if (offersPurchase)
        {
            links.Children.Add(Link(Strings.Get("License/BuyLicense"), SupportLinks.Pricing(SupportReferrer.LicenseSettings)));
        }

        links.Children.Add(Link(Strings.Get("License/LearnMore"), SupportLinks.LicensingGuide));
        body.Children.Add(links);
    }

    private Border ActionsCard(LicenseService license)
    {
        var deactivate = new Button { Content = Strings.Get("License/DeactivateButton"), IsEnabled = !license.IsValidating };
        deactivate.Click += async (_, _) =>
        {
            if (await new DialogService(this).ConfirmAsync(Strings.Get("License/DeactivateTitle"), Strings.Get("License/DeactivateMessage"), Strings.Get("License/Deactivate"), destructive: true))
            {
                // A server that could not be reached is reported on the page the deactivation lands on.
                await license.DeactivateAsync();
            }
        };
        var row = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 8 };
        row.Children.Add(Link(Strings.Get("License/ManageAccount"), SupportLinks.Account));
        row.Children.Add(deactivate);
        return CardOf(row);
    }

    private static Grid SectionHeader(string title, FrameworkElement trailing)
    {
        var grid = new Grid { Margin = new Thickness(0, 20, 0, 4) };
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        grid.Children.Add(new TextBlock { Text = title, Style = (Style)Application.Current.Resources["BodyStrongTextBlockStyle"] });
        trailing.VerticalAlignment = VerticalAlignment.Center;
        Grid.SetColumn(trailing, 1);
        grid.Children.Add(trailing);
        return grid;
    }

    private static Border CardOf(FrameworkElement content) =>
        new() { Style = (Style)Application.Current.Resources["CardBorderStyle"], Child = content, Padding = new Thickness(16, 12, 16, 12) };

    private static HyperlinkButton Link(string text, Uri destination) => new() { Content = text, NavigateUri = destination };

    private static TextBlock Secondary(string text) => new()
    {
        Text = text,
        TextWrapping = TextWrapping.Wrap,
        Style = (Style)Application.Current.Resources["CaptionTextBlockStyle"],
        Foreground = (Brush)Application.Current.Resources["TextFillColorSecondaryBrush"],
    };

    private static StackPanel Caution(string text)
    {
        var icon = new FontIcon { Glyph = "\xE7BA", FontSize = 14, Foreground = (Brush)Application.Current.Resources["SystemFillColorCautionBrush"] };
        AutomationProperties.SetAccessibilityView(icon, Microsoft.UI.Xaml.Automation.Peers.AccessibilityView.Raw);
        var row = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 8 };
        row.Children.Add(icon);
        row.Children.Add(new TextBlock { Text = text, TextWrapping = TextWrapping.Wrap, MaxWidth = 720 });
        return row;
    }

    private static StackPanel Loading(string text)
    {
        var row = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 8 };
        row.Children.Add(new ProgressRing { IsActive = true, Width = 16, Height = 16 });
        row.Children.Add(Secondary(text));
        return row;
    }

    private static StackPanel IncludedLabel()
    {
        var icon = new FontIcon { Glyph = "\xEC61", FontSize = 14, Foreground = (Brush)Application.Current.Resources["SystemFillColorSuccessBrush"] };
        AutomationProperties.SetAccessibilityView(icon, Microsoft.UI.Xaml.Automation.Peers.AccessibilityView.Raw);
        var row = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 6 };
        row.Children.Add(icon);
        row.Children.Add(Secondary(Strings.Get("License/Included")));
        return row;
    }

    private static Button RetryButton(Func<Task> retry)
    {
        var button = new Button { Content = Strings.Get("License/TryAgain") };
        button.Click += async (_, _) => await retry();
        return button;
    }

    /// <summary>
    /// The key field, Activate and the one error path, shared by the landing card and the renewal card. It outlives
    /// each render of the page, so a key being typed, an activation in flight and its error survive the service's
    /// change notifications.
    /// </summary>
    private sealed class LicenseActivationForm
    {
        private readonly LicenseService _license;
        private readonly TextBox _entry = new() { PlaceholderText = Strings.Get("License/KeyPlaceholder"), FontFamily = new FontFamily("Consolas"), IsSpellCheckEnabled = false };
        private readonly Button _activate = new() { Content = Strings.Get("License/Activate"), IsEnabled = false };
        private readonly ProgressRing _ring = new() { Width = 16, Height = 16, IsActive = false, Visibility = Visibility.Collapsed };
        private readonly TextBlock _error = new() { TextWrapping = TextWrapping.Wrap };
        private readonly HyperlinkButton _manageDevices = new() { Content = Strings.Get("License/ManageDevices"), NavigateUri = SupportLinks.AccountMachines, Visibility = Visibility.Collapsed };
        private readonly StackPanel _failure = new() { Spacing = 4, Visibility = Visibility.Collapsed };
        private bool _activating;

        public LicenseActivationForm(LicenseService license)
        {
            _license = license;
            _activate.Style = (Style)Application.Current.Resources["AccentButtonStyle"];
            AutomationProperties.SetName(_entry, Strings.Get("License/KeyPlaceholder"));
            _entry.TextChanged += (_, _) => UpdateEnabled();
            _entry.KeyDown += async (_, e) =>
            {
                if (e.Key == Windows.System.VirtualKey.Enter)
                {
                    e.Handled = true;
                    await ActivateAsync();
                }
            };
            _activate.Click += async (_, _) => await ActivateAsync();

            var icon = new FontIcon { Glyph = "\xE7BA", FontSize = 14, Foreground = (Brush)Application.Current.Resources["SystemFillColorCautionBrush"] };
            var message = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 8 };
            message.Children.Add(icon);
            message.Children.Add(_error);
            _failure.Children.Add(message);
            _failure.Children.Add(_manageDevices);

            var buttons = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 10 };
            buttons.Children.Add(_activate);
            buttons.Children.Add(_ring);
            Root.Children.Add(_entry);
            Root.Children.Add(_failure);
            Root.Children.Add(buttons);
        }

        public StackPanel Root { get; } = new() { Spacing = 10 };

        /// <summary>Takes the form out of the card it sat in, so the next render can place it.</summary>
        public void Detach()
        {
            switch (Root.Parent)
            {
                case Panel panel:
                    panel.Children.Remove(Root);
                    break;
                case Border border:
                    border.Child = null;
                    break;
            }
        }

        private void UpdateEnabled() => _activate.IsEnabled = !_activating && _entry.Text.Trim().Length > 0;

        private async Task ActivateAsync()
        {
            var entry = _entry.Text.Trim();
            if (entry.Length == 0 || _activating)
            {
                return;
            }

            _activating = true;
            _failure.Visibility = Visibility.Collapsed;
            _ring.IsActive = true;
            _ring.Visibility = Visibility.Visible;
            UpdateEnabled();
            try
            {
                await _license.ActivateAsync(entry);
                _entry.Text = string.Empty;
            }
            catch (Exception ex) when (ex is LicenseException or IOException or UnauthorizedAccessException or System.ComponentModel.Win32Exception)
            {
                _error.Text = LicenseNames.Error(ex);
                _manageDevices.Visibility = LicensePresentation.OffersManageDevices(ex, entry) ? Visibility.Visible : Visibility.Collapsed;
                _failure.Visibility = Visibility.Visible;
            }
            finally
            {
                _activating = false;
                _ring.IsActive = false;
                _ring.Visibility = Visibility.Collapsed;
                UpdateEnabled();
            }
        }
    }
}
