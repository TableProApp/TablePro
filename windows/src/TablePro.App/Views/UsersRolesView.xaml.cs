using Microsoft.UI.Text;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Input;
using Microsoft.UI.Xaml.Media;
using TablePro.App.Helpers;
using TablePro.App.Services;
using TablePro.App.ViewModels;
using TablePro.Core.Principals;
using Windows.ApplicationModel.DataTransfer;
using Windows.System;

namespace TablePro.App.Views;

/// <summary>
/// The Users and Roles editor: principals on the left; on the right a principal's privileges, as a scope tree beside a
/// checklist, or its attributes. Edits are staged and run together from the bar at the bottom.
/// </summary>
public sealed partial class UsersRolesView : UserControl
{
    private readonly DialogService _dialogs;
    private readonly Dictionary<string, bool> _expandedSections = [];

    public UsersRolesView(UsersRolesViewModel viewModel, DialogService dialogs)
    {
        ViewModel = viewModel;
        _dialogs = dialogs;
        InitializeComponent();

        // Scoped to the editor, so Ctrl+Z here never reaches a query tab's own undo.
        AddAccelerator(UndoButton, VirtualKey.Z);
        AddAccelerator(RedoButton, VirtualKey.Y);

        viewModel.DetailChanged += (_, _) => RenderDetail();
        ActualThemeChanged += (_, _) => RenderDetail();
        Loaded += async (_, _) =>
        {
            RenderDetail();
            await viewModel.LoadAsync();
        };
    }

    public UsersRolesViewModel ViewModel { get; }

    private void AddAccelerator(Button button, VirtualKey key) =>
        button.KeyboardAccelerators.Add(new KeyboardAccelerator { Key = key, Modifiers = VirtualKeyModifiers.Control, ScopeOwner = Root });

    // MARK: Detail

    private void RenderDetail()
    {
        var info = ViewModel.SelectedInfo;
        var hasSelection = info is not null;
        NoSelection.Visibility = hasSelection ? Visibility.Collapsed : Visibility.Visible;
        DetailHeader.Visibility = hasSelection ? Visibility.Visible : Visibility.Collapsed;
        PrivilegesPane.Visibility = hasSelection && ViewModel.Segment == UsersRolesSegment.Privileges ? Visibility.Visible : Visibility.Collapsed;
        AttributesPane.Visibility = hasSelection && ViewModel.Segment == UsersRolesSegment.Attributes ? Visibility.Visible : Visibility.Collapsed;
        if (info is null)
        {
            return;
        }

        DetailGlyph.Glyph = info.IsRole ? "" : "";
        DetailTitle.Text = ViewModel.SelectedRow?.Title ?? info.Ref.DisplayName;
        DetailModified.Visibility = ViewModel.Tracker.Stage(info.Ref) == PrincipalStage.Unchanged ? Visibility.Collapsed : Visibility.Visible;
        DetailModified.Text = ViewModel.SelectedRow?.StageDescription is { Length: > 0 } stage ? stage : Strings.Get("Users/StageModifiedShort");

        // Every edit redraws the pane, so the control that made it is found again by its tag and keeps the focus.
        var panel = ViewModel.Segment == UsersRolesSegment.Privileges ? (Panel)Checklist : AttributesForm;
        var focused = FocusedTag(panel);
        if (ViewModel.Segment == UsersRolesSegment.Privileges)
        {
            RenderChecklist();
        }
        else
        {
            RenderAttributes(info);
        }

        if (focused is not null)
        {
            DispatcherQueue.TryEnqueue(() => RestoreFocus(panel, focused));
        }
    }

    private string? FocusedTag(Panel panel)
    {
        if (XamlRoot is null || FocusManager.GetFocusedElement(XamlRoot) is not DependencyObject focused)
        {
            return null;
        }

        // The focus may sit in a part of a control, such as the text box inside a NumberBox; the tag is on the control.
        string? tag = null;
        for (var parent = focused; parent is not null; parent = VisualTreeHelper.GetParent(parent))
        {
            if (ReferenceEquals(parent, panel))
            {
                return tag;
            }

            tag ??= (parent as FrameworkElement)?.Tag as string;
        }

        return null;
    }

    private static bool RestoreFocus(DependencyObject parent, string tag)
    {
        for (var i = 0; i < VisualTreeHelper.GetChildrenCount(parent); i++)
        {
            var child = VisualTreeHelper.GetChild(parent, i);
            if (child is Control { Tag: string candidate } control && candidate == tag)
            {
                return control.Focus(FocusState.Keyboard);
            }

            if (RestoreFocus(child, tag))
            {
                return true;
            }
        }

        return false;
    }

    private void RenderChecklist()
    {
        Checklist.Children.Clear();
        GrantsErrorBar.IsOpen = ViewModel.GrantsError is not null;
        GrantsErrorBar.Message = ViewModel.GrantsError ?? string.Empty;
        var scope = ViewModel.SelectedScope;
        ScopeTitle.Text = scope?.Scope.DisplayPath ?? string.Empty;
        ChecklistHeader.Visibility = scope is null ? Visibility.Collapsed : Visibility.Visible;

        string? placeholder = null;
        var sections = ViewModel.Sections;
        if (scope is null)
        {
            placeholder = Strings.Get("Users/ChecklistNoScope");
        }
        else if (ViewModel.GrantsError is not null)
        {
            placeholder = string.Empty;
        }
        else if (sections.Count == 0)
        {
            placeholder = ViewModel.PrivilegeFilter.Trim().Length > 0 ? Strings.Get("Users/ChecklistNoMatch") : Strings.Get("Users/ChecklistNoneGrantable");
        }

        ChecklistPlaceholder.Text = placeholder ?? string.Empty;
        ChecklistPlaceholder.Visibility = string.IsNullOrEmpty(placeholder) ? Visibility.Collapsed : Visibility.Visible;
        if (placeholder is not null)
        {
            return;
        }

        foreach (var section in sections)
        {
            Checklist.Children.Add(SectionView(section));
        }
    }

    private Expander SectionView(PrivilegeSection section)
    {
        var state = ViewModel.SectionState(section);
        var title = UsersNames.CategoryTitle(section.Category);
        var header = new CheckBox
        {
            Content = title,
            IsThreeState = true,
            IsChecked = state,
            FontWeight = FontWeights.SemiBold,
            Tag = "section:" + section.Category.Key,
        };
        Describe(header, title, state switch
        {
            true => Strings.Get("Users/SectionGranted"),
            false => Strings.Get("Users/SectionNotGranted"),
            _ => Strings.Get("Users/SectionPartlyGranted"),
        });

        // A mixed or empty section grants everything; only a fully granted one revokes.
        header.Click += (_, _) => ViewModel.SetGranted(ViewModel.SectionState(section) != true, section.Privileges.Select(p => p.Name).ToArray());

        var rows = new StackPanel { Spacing = 2 };
        foreach (var privilege in section.Privileges)
        {
            rows.Children.Add(PrivilegeRow(privilege));
        }

        var key = section.Category.Key;
        var expander = new Expander
        {
            Header = header,
            Content = rows,
            IsExpanded = _expandedSections.TryGetValue(key, out var expanded) ? expanded : !section.Category.IsCollapsedByDefault,
            HorizontalAlignment = HorizontalAlignment.Stretch,
            HorizontalContentAlignment = HorizontalAlignment.Stretch,
        };
        expander.Expanding += (_, _) => _expandedSections[key] = true;
        expander.Collapsed += (_, _) => _expandedSections[key] = false;
        return expander;
    }

    private Grid PrivilegeRow(PrivilegeDescriptor privilege)
    {
        var granted = ViewModel.IsGranted(privilege.Name);
        var box = new CheckBox
        {
            Content = privilege.Label,
            IsChecked = granted,
            FontWeight = ViewModel.IsStaged(privilege.Name) ? FontWeights.SemiBold : FontWeights.Normal,
            MinWidth = 0,
            Tag = "privilege:" + privilege.Name,
        };
        box.Click += (_, _) => ViewModel.SetGranted(box.IsChecked == true, [privilege.Name]);

        var row = new Grid { ColumnSpacing = 8 };
        row.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        row.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        row.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        row.Children.Add(box);

        if (ViewModel.IsGrantable(privilege.Name))
        {
            var grantable = new FontIcon
            {
                Glyph = "",
                FontSize = 12,
                VerticalAlignment = VerticalAlignment.Center,
                Foreground = ThemeResources.Brush(this, "TextFillColorSecondaryBrush"),
            };
            ToolTipService.SetToolTip(grantable, Strings.Get("Users/GrantableToolTip"));
            AutomationProperties.SetName(grantable, Strings.Get("Users/GrantableName"));
            Grid.SetColumn(grantable, 1);
            row.Children.Add(grantable);
        }

        var effect = ViewModel.Effectiveness(privilege.Name);
        if (UsersNames.EffectivenessDescription(effect) is { } description)
        {
            var text = new TextBlock
            {
                Text = description,
                Style = (Style)Application.Current.Resources["CaptionTextBlockStyle"],
                Foreground = ThemeResources.Brush(this, "TextFillColorSecondaryBrush"),
                VerticalAlignment = VerticalAlignment.Center,
                TextTrimming = TextTrimming.CharacterEllipsis,
            };
            if (UsersNames.EffectivenessDetail(effect) is { } detail)
            {
                ToolTipService.SetToolTip(text, detail);
            }

            Grid.SetColumn(text, 2);
            row.Children.Add(text);
        }

        return row;
    }

    private void RenderAttributes(PrincipalInfo info)
    {
        AttributesForm.Children.Clear();
        if (ViewModel.SelectedDraft is not { } draft)
        {
            return;
        }

        var features = ViewModel.Features;

        AddHeader(Strings.Get("Users/IdentityHeader"));
        AddValue(Strings.Get("Common/Name"), draft.Ref.Name);
        if (features.HostScoping)
        {
            AddValue(Strings.Get("Users/Host"), draft.Ref.Host ?? "%");
        }

        if (ViewModel.CanRename(info.Ref))
        {
            AttributesForm.Children.Add(FormButton(Strings.Get("Users/RenameEllipsis"), "rename", async () => await RenameAsync(info.Ref)));
        }

        AddHeader(Strings.Get("Users/AuthenticationHeader"));
        var login = new ToggleSwitch { Header = Strings.Get("Users/CanLogIn"), IsOn = draft.CanLogin, IsEnabled = ViewModel.AllowsLoginToggle(info), Tag = "login" };
        login.Toggled += (_, _) =>
        {
            if (login.IsOn != draft.CanLogin)
            {
                ViewModel.EditSelected(d => d with { CanLogin = login.IsOn });
            }
        };
        AttributesForm.Children.Add(login);
        if (!info.IsRole || features.RoleLogin)
        {
            AttributesForm.Children.Add(FormButton(Strings.Get("Users/ChangePasswordButton"), "password", async () => await ChangePasswordAsync(info.Ref)));
        }

        if (ViewModel.Tracker.HasPendingPassword(info.Ref))
        {
            AddNote(Strings.Get("Users/PendingPasswordNote"));
        }

        if (draft.Attributes.Count > 0)
        {
            AddHeader(Strings.Get("Users/RoleAttributesHeader"));
            foreach (var attribute in draft.Attributes)
            {
                var box = new CheckBox { Content = UsersNames.AttributeLabel(attribute), IsChecked = attribute.IsEnabled, Tag = "attribute:" + attribute.Key };
                box.Click += (_, _) => ViewModel.EditSelected(d => d with
                {
                    Attributes = [.. d.Attributes.Select(a => a.Key == attribute.Key ? a with { IsEnabled = box.IsChecked == true } : a)],
                });
                AttributesForm.Children.Add(box);
            }

            if (draft.Attributes.Any(a => a is { Key: "SUPERUSER", IsEnabled: true }))
            {
                AddNote(Strings.Get("Users/SuperuserNote"));
            }
        }

        if (features.RoleMembership)
        {
            AddHeader(Strings.Get("Users/MembershipHeader"));
            AddValue(Strings.Get("Users/MemberOf"), draft.MemberOf.Count == 0 ? Strings.Get("Common/None") : string.Join(", ", draft.MemberOf));
            AttributesForm.Children.Add(FormButton(Strings.Get("Users/EditMembershipButton"), "membership", async () => await EditMembershipAsync(info.Ref)));
        }

        if (features.ConnectionLimit)
        {
            AddHeader(Strings.Get("Users/LimitsHeader"));
            var limit = new NumberBox
            {
                Header = Strings.Get("Users/ConnectionLimit"),
                PlaceholderText = Strings.Get("Users/Unlimited"),
                Minimum = 0,
                SmallChange = 1,
                SpinButtonPlacementMode = NumberBoxSpinButtonPlacementMode.Compact,
                Value = draft.ConnectionLimit ?? double.NaN,
                HorizontalAlignment = HorizontalAlignment.Left,
                MinWidth = 160,
                Tag = "limit",
            };
            limit.ValueChanged += (_, e) =>
            {
                int? value = double.IsNaN(e.NewValue) ? null : (int)Math.Round(e.NewValue);
                if (value != draft.ConnectionLimit)
                {
                    ViewModel.EditSelected(d => d with { ConnectionLimit = value });
                }
            };
            AttributesForm.Children.Add(limit);
        }
    }

    private void AddHeader(string text) =>
        AttributesForm.Children.Add(new TextBlock
        {
            Text = text,
            Style = (Style)Application.Current.Resources["BodyStrongTextBlockStyle"],
            Margin = new Thickness(0, AttributesForm.Children.Count == 0 ? 0 : 16, 0, 0),
        });

    private void AddValue(string label, string value)
    {
        var row = new Grid { ColumnSpacing = 12 };
        row.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(120) });
        row.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        row.Children.Add(new TextBlock { Text = label, Foreground = ThemeResources.Brush(this, "TextFillColorSecondaryBrush") });
        var text = new TextBlock { Text = value, IsTextSelectionEnabled = true, TextWrapping = TextWrapping.Wrap };
        Grid.SetColumn(text, 1);
        row.Children.Add(text);
        AttributesForm.Children.Add(row);
    }

    private void AddNote(string text) =>
        AttributesForm.Children.Add(new TextBlock
        {
            Text = text,
            Style = (Style)Application.Current.Resources["CaptionTextBlockStyle"],
            Foreground = ThemeResources.Brush(this, "TextFillColorSecondaryBrush"),
            TextWrapping = TextWrapping.Wrap,
        });

    private static Button FormButton(string text, string tag, Func<Task> action)
    {
        var button = new Button { Content = text, Tag = tag };
        button.Click += async (_, _) => await action();
        return button;
    }

    private static void Describe(UIElement element, string name, string status)
    {
        AutomationProperties.SetName(element, name);
        AutomationProperties.SetItemStatus(element, status);
    }

    // MARK: Events

    private void OnSegmentChanged(SelectorBar sender, SelectorBarSelectionChangedEventArgs args)
    {
        if (Enum.TryParse<UsersRolesSegment>(sender.SelectedItem?.Tag as string, out var segment))
        {
            ViewModel.Segment = segment;
        }
    }

    private void OnScopeModeChanged(object sender, SelectionChangedEventArgs e) =>
        ViewModel.ScopeMode = ScopeModes.SelectedIndex == 1 ? ScopeViewMode.Granted : ScopeViewMode.All;

    private async void OnScopeExpanding(TreeView sender, TreeViewExpandingEventArgs args)
    {
        if (args.Item is ScopeNodeItem node)
        {
            await ViewModel.ExpandAsync(node);
        }
    }

    private void OnScopeSelectionChanged(TreeView sender, TreeViewSelectionChangedEventArgs args) =>
        ViewModel.SelectedScope = sender.SelectedItem as ScopeNodeItem;

    private void OnGrantAllClicked(object sender, RoutedEventArgs e) => ViewModel.SetAllGranted(true);

    private void OnRevokeAllClicked(object sender, RoutedEventArgs e) => ViewModel.SetAllGranted(false);

    private async void OnRetryGrantsClicked(object sender, RoutedEventArgs e)
    {
        if (ViewModel.Selection is { } selection)
        {
            await ViewModel.LoadGrantsAsync(selection);
        }
    }

    private async void OnCreateClicked(object sender, RoutedEventArgs e) => await UsersRolesDialogs.CreateAsync(_dialogs, ViewModel);

    private async void OnDropClicked(object sender, RoutedEventArgs e)
    {
        if (ViewModel.Selection is { } selection)
        {
            await DropAsync(selection);
        }
    }

    private void OnPrincipalRightTapped(object sender, RightTappedRoutedEventArgs e)
    {
        if ((e.OriginalSource as FrameworkElement)?.DataContext is not PrincipalRowItem row)
        {
            return;
        }

        ViewModel.SelectedRow = row;
        var menu = new MenuFlyout();
        if (!row.IsRole || ViewModel.Features.RoleLogin)
        {
            menu.Items.Add(GridCommands.Item(Strings.Get("Users/ChangePasswordMenu"),"", async () => await ChangePasswordAsync(row.Ref)));
        }

        menu.Items.Add(GridCommands.Item(Strings.Get("Users/CopyPrivilegesFromMenu"),"", async () => await UsersRolesDialogs.CopyPrivilegesAsync(_dialogs, ViewModel, row.Ref)));
        if (ViewModel.CanRename(row.Ref))
        {
            menu.Items.Add(GridCommands.Item(Strings.Get("Users/RenameEllipsis"),"", async () => await RenameAsync(row.Ref)));
        }

        menu.Items.Add(GridCommands.Item(Strings.Get("Users/CopyNameMenu"),"", () => CopyText(row.Ref.DisplayName)));
        menu.Items.Add(new MenuFlyoutSeparator());
        if (row.Stage == PrincipalStage.Dropped)
        {
            menu.Items.Add(GridCommands.Item(Strings.Get("Users/UndoStagedDropMenu"),"", () => ViewModel.KeepPrincipal(row.Ref)));
        }
        else
        {
            menu.Items.Add(GridCommands.Item(Strings.Get("Users/DropMenu"),"", async () => await DropAsync(row.Ref)));
        }

        menu.ShowAt(PrincipalList, e.GetPosition(PrincipalList));
        e.Handled = true;
    }

    // MARK: Actions

    private async Task DropAsync(PrincipalRef principal)
    {
        foreach (var owner in await ViewModel.DropAsync(principal))
        {
            if (await UsersRolesDialogs.DropOwnedAsync(_dialogs, ViewModel, owner) is { } options)
            {
                ViewModel.ConfirmDrop(owner, options);
            }
        }
    }

    private Task ChangePasswordAsync(PrincipalRef principal) => UsersRolesDialogs.ChangePasswordAsync(_dialogs, ViewModel, principal);

    private Task RenameAsync(PrincipalRef principal) => UsersRolesDialogs.RenameAsync(_dialogs, ViewModel, principal);

    private Task EditMembershipAsync(PrincipalRef principal) => UsersRolesDialogs.EditMembershipAsync(_dialogs, ViewModel, principal);

    private static void CopyText(string text)
    {
        var package = new DataPackage();
        package.SetText(text);
        Clipboard.SetContent(package);
    }
}
