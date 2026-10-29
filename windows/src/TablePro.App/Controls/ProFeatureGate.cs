using System.Globalization;
using Microsoft.UI.Dispatching;
using Microsoft.UI.Text;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Markup;
using TablePro.App.Helpers;
using TablePro.App.Localization;
using TablePro.App.Services;
using TablePro.Core.Licensing;
using TablePro.Storage.Licensing;

namespace TablePro.App.Controls;

/// <summary>
/// The one gate every paid feature goes through, the macOS <c>requiresPro</c> modifier and its companions. As a
/// control it wraps the feature: while the license covers it the child shows, otherwise the child leaves the tree and
/// the overlay explains why, worded for the reason (no license, expired, unchecked, too small a plan) with the way out
/// as its button. It follows the license while loaded, so activating or removing one updates an open window at once.
/// <see cref="EnsureAsync"/> is the same gate for an action reached from a menu, and <see cref="Badge"/> marks a
/// single option the license unlocks.
/// </summary>
[ContentProperty(Name = nameof(Child))]
public sealed partial class ProFeatureGate : UserControl
{
    public static readonly DependencyProperty FeatureProperty = DependencyProperty.Register(
        nameof(Feature), typeof(ProFeature), typeof(ProFeatureGate), new PropertyMetadata(ProFeature.ResultCharts, (d, _) => ((ProFeatureGate)d).Follow()));

    public static readonly DependencyProperty ChildProperty = DependencyProperty.Register(
        nameof(Child), typeof(UIElement), typeof(ProFeatureGate), new PropertyMetadata(null, (d, _) => ((ProFeatureGate)d).Render()));

    private static readonly ProFeatureAccess NoLicense = new(ProFeatureAccessKind.Unlicensed);
    private static LicenseService? _license;
    private static Action? _openLicenseSettings;

    private readonly Grid _root = new();
    private readonly ContentPresenter _presenter = new() { HorizontalContentAlignment = HorizontalAlignment.Stretch, VerticalContentAlignment = VerticalAlignment.Stretch };
    private readonly DispatcherQueue _dispatcher;
    private ProFeatureMonitor? _monitor;
    private ProFeatureAccess? _shown;

    public ProFeatureGate()
    {
        _dispatcher = DispatcherQueue.GetForCurrentThread();
        _root.Children.Add(_presenter);
        Content = _root;
        IsTabStop = false;
        Loaded += (_, _) => Follow();
        Unloaded += (_, _) => StopFollowing();

        // The overlay's brushes are looked up for the theme it renders in, so a theme change rebuilds it.
        ActualThemeChanged += (_, _) => Render();
    }

    /// <summary>Raised on the UI thread when the license starts or stops covering <see cref="Feature"/>.</summary>
    public event EventHandler? AccessChanged;

    public ProFeature Feature
    {
        get => (ProFeature)GetValue(FeatureProperty);
        set => SetValue(FeatureProperty, value);
    }

    public UIElement? Child
    {
        get => (UIElement?)GetValue(ChildProperty);
        set => SetValue(ChildProperty, value);
    }

    public ProFeatureAccess Access => _monitor?.Access ?? Check(Feature);

    public bool IsUnlocked => Access.IsAvailable;

    /// <summary>
    /// The license every gate reads and the way to its settings page. Launch sets it before a workspace window can
    /// open; until then nothing is unlocked, as with no license at all.
    /// </summary>
    public static void UseLicense(LicenseService license, Action openLicenseSettings)
    {
        _license = license;
        _openLicenseSettings = openLicenseSettings;
    }

    public static ProFeatureAccess Check(ProFeature feature) => _license?.CheckFeature(feature) ?? NoLicense;

    public static bool IsAvailable(ProFeature feature) => Check(feature).IsAvailable;

    /// <summary>
    /// Calls <paramref name="changed"/> on <paramref name="dispatcher"/> whenever the license starts or stops covering
    /// <paramref name="feature"/>, for a view that keeps working without it and only words itself differently. Dispose
    /// the result when the view unloads.
    /// </summary>
    public static IDisposable Watch(ProFeature feature, DispatcherQueue dispatcher, Action changed)
    {
        ArgumentNullException.ThrowIfNull(dispatcher);
        ArgumentNullException.ThrowIfNull(changed);
        if (_license is not { } license)
        {
            return new ProFeatureWatch(null);
        }

        var monitor = new ProFeatureMonitor(license, feature);
        monitor.AccessChanged += (_, _) => dispatcher.TryEnqueue(() => changed());
        return new ProFeatureWatch(monitor);
    }

    /// <summary>
    /// The gate for an action reached from a menu: true when the license covers <paramref name="feature"/>, otherwise
    /// it explains what the feature needs, offers the way to it, and returns false. The menu item itself stays enabled,
    /// as on macOS, because a dimmed command nobody notices tells them nothing about what the license is for.
    /// </summary>
    public static async Task<bool> EnsureAsync(ProFeature feature, DialogService dialogs)
    {
        ArgumentNullException.ThrowIfNull(dialogs);
        if (IsAvailable(feature))
        {
            return true;
        }

        var action = ProFeatureGates.PromptAction(feature);
        var (title, message, primary, close) = action == ProFeaturePromptAction.PurchaseLicense
            ? (Strings.Format("License/PromptNeedsLicense", LicenseNames.Feature(feature), LicenseNames.Tier(feature.RequiredTier())), PromptMessage(feature), Strings.Get("License/GatePurchase"), Strings.Get("License/NotNow"))
            : (PlanRequirement(feature), LicenseNames.FeatureDescription(feature), Strings.Get("License/ViewLicense"), Strings.Get("Common/Cancel"));
        var body = new TextBlock { Text = message, TextWrapping = TextWrapping.Wrap, MaxWidth = 460 };
        if (await dialogs.ShowAsync(dialogs.Create(title, body, primary, close)) == ContentDialogResult.Primary)
        {
            if (action == ProFeaturePromptAction.PurchaseLicense)
            {
                await OpenPricingAsync(feature);
            }
            else
            {
                _openLicenseSettings?.Invoke();
            }
        }

        return false;
    }

    /// <summary>
    /// The plan's name on a pill beside an option the license unlocks, the macOS ProBadge. It links to the pricing page,
    /// so the locked option is never a dead end, and its tooltip says what the feature does.
    /// </summary>
    public static HyperlinkButton Badge(ProFeature feature)
    {
        var pill = new Border
        {
            CornerRadius = new CornerRadius(8),
            Padding = new Thickness(6, 1, 6, 1),
            Background = (Microsoft.UI.Xaml.Media.Brush)Application.Current.Resources["AccentFillColorDefaultBrush"],
            Child = new TextBlock
            {
                Text = LicenseNames.Tier(feature.RequiredTier()).ToUpper(CultureInfo.CurrentCulture),
                FontSize = 10,
                FontWeight = FontWeights.Bold,
                Foreground = (Microsoft.UI.Xaml.Media.Brush)Application.Current.Resources["TextOnAccentFillColorPrimaryBrush"],
            },
        };
        var badge = new HyperlinkButton
        {
            Content = pill,
            Padding = new Thickness(0),
            VerticalAlignment = VerticalAlignment.Center,
            NavigateUri = SupportLinks.Pricing(SupportReferrer.FeatureGate, feature),
        };
        ToolTipService.SetToolTip(badge, LicenseNames.FeatureDescription(feature));
        AutomationProperties.SetName(badge, PlanRequirement(feature));
        AutomationProperties.SetHelpText(badge, Strings.Get("License/OpensPricing"));
        return badge;
    }

    private static string PlanRequirement(ProFeature feature) =>
        Strings.Format("License/GatePlanRequirement", LicenseNames.Feature(feature), LicenseNames.Tier(feature.RequiredTier()));

    // Data Rewind's prompt meets someone who has just saved the wrong thing, so it says where their saves are kept.
    private static string PromptMessage(ProFeature feature) =>
        feature == ProFeature.DataRewind ? Strings.Get("License/RewindPromptMessage") : LicenseNames.FeatureDescription(feature);

    private static async Task OpenPricingAsync(ProFeature feature) =>
        await Windows.System.Launcher.LaunchUriAsync(SupportLinks.Pricing(SupportReferrer.FeatureGate, feature));

    private void Follow()
    {
        StopFollowing();
        if (IsLoaded && _license is { } license)
        {
            _monitor = new ProFeatureMonitor(license, Feature);
            _monitor.AccessChanged += OnAccessChanged;
        }

        Render();
    }

    private void StopFollowing()
    {
        if (_monitor is { } monitor)
        {
            monitor.AccessChanged -= OnAccessChanged;
            monitor.Dispose();
            _monitor = null;
        }
    }

    // The license changes on whichever thread ran the check; the overlay is rebuilt on the UI thread.
    private void OnAccessChanged(object? sender, EventArgs e) => _dispatcher.TryEnqueue(Render);

    private void Render()
    {
        var access = Access;
        var child = Child;
        var unlocked = access.IsAvailable;

        // The child leaves the tree while locked, so a chart is neither drawn nor laid out behind the overlay.
        _presenter.Content = unlocked ? child : null;
        while (_root.Children.Count > 1)
        {
            _root.Children.RemoveAt(1);
        }

        if (ProFeatureGates.Overlay(access) is { } overlay)
        {
            _root.Children.Add(Overlay(overlay));
        }

        var changed = _shown is { } previous && previous.IsAvailable != unlocked;
        _shown = access;
        if (changed)
        {
            AccessChanged?.Invoke(this, EventArgs.Empty);
        }
    }

    private Grid Overlay(ProFeatureGateContent content)
    {
        var feature = Feature;
        var stack = new StackPanel { Spacing = 12, HorizontalAlignment = HorizontalAlignment.Center, VerticalAlignment = VerticalAlignment.Center, MaxWidth = 420, Padding = new Thickness(16) };
        stack.Children.Add(new FontIcon
        {
            Glyph = LicenseNames.FeatureGlyph(feature),
            FontSize = 40,
            Foreground = ThemeResources.Brush(this, "TextFillColorSecondaryBrush"),
            HorizontalAlignment = HorizontalAlignment.Center,
        });

        var headline = new TextBlock
        {
            Text = content.Headline switch
            {
                ProFeatureGateHeadline.Expired => Strings.Get("License/GateExpired"),
                ProFeatureGateHeadline.ValidationFailed => Strings.Get("License/GateValidationFailed"),
                _ => PlanRequirement(feature),
            },
            Style = (Style)Application.Current.Resources["BodyStrongTextBlockStyle"],
            TextWrapping = TextWrapping.Wrap,
            TextAlignment = TextAlignment.Center,
            HorizontalAlignment = HorizontalAlignment.Center,
        };
        AutomationProperties.SetHeadingLevel(headline, Microsoft.UI.Xaml.Automation.Peers.AutomationHeadingLevel.Level2);
        stack.Children.Add(headline);
        stack.Children.Add(new TextBlock
        {
            Text = content.ShowsFeatureDescription ? LicenseNames.FeatureDescription(feature) : Strings.Get("License/GateValidationFailedMessage"),
            TextWrapping = TextWrapping.Wrap,
            TextAlignment = TextAlignment.Center,
            HorizontalAlignment = HorizontalAlignment.Center,
            Foreground = ThemeResources.Brush(this, "TextFillColorSecondaryBrush"),
        });

        var button = new Button
        {
            Style = (Style)Application.Current.Resources["AccentButtonStyle"],
            HorizontalAlignment = HorizontalAlignment.Center,
            Content = content.Action switch
            {
                ProFeatureGateAction.RetryValidation => Strings.Get("License/GateRetry"),
                ProFeatureGateAction.UpgradePlan => Strings.Get("License/UpgradePlan"),
                _ => Strings.Get("License/GateActivate"),
            },
        };
        button.Click += async (_, _) =>
        {
            switch (content.Action)
            {
                case ProFeatureGateAction.RetryValidation when _license is { } license:
                    button.IsEnabled = false;
                    try
                    {
                        await license.RevalidateAsync();
                    }
                    finally
                    {
                        button.IsEnabled = true;
                    }

                    break;
                case ProFeatureGateAction.UpgradePlan:
                    await OpenPricingAsync(feature);
                    break;
                case ProFeatureGateAction.ActivateLicense:
                    _openLicenseSettings?.Invoke();
                    break;
            }
        };
        stack.Children.Add(button);

        if (content.Link is { } link)
        {
            stack.Children.Add(new HyperlinkButton
            {
                HorizontalAlignment = HorizontalAlignment.Center,
                Content = link == ProFeatureGateLink.RenewLicense ? Strings.Get("License/RenewLicense") : Strings.Get("License/GatePurchase"),
                NavigateUri = SupportLinks.Pricing(SupportReferrer.FeatureGate, feature),
            });
        }

        return new Grid
        {
            Background = ThemeResources.Brush(this, "LayerFillColorDefaultBrush"),
            Children = { new ScrollViewer { Content = stack, VerticalAlignment = VerticalAlignment.Center } },
        };
    }

    private sealed class ProFeatureWatch(ProFeatureMonitor? monitor) : IDisposable
    {
        public void Dispose() => monitor?.Dispose();
    }
}
