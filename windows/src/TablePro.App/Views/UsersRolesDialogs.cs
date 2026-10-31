using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using TablePro.App.Helpers;
using TablePro.App.Services;
using TablePro.App.ViewModels;
using TablePro.Core.Principals;

namespace TablePro.App.Views;

/// <summary>
/// The Users and Roles editor's sheets: create, change password, rename, membership, copy privileges and the choice a
/// PostgreSQL drop needs for owned objects. Each stages its result in the view model; nothing here touches the server.
/// </summary>
internal static class UsersRolesDialogs
{
    public static async Task CreateAsync(DialogService dialogs, UsersRolesViewModel viewModel)
    {
        var features = viewModel.Features;
        var panel = new StackPanel { Spacing = 12, MinWidth = 400 };

        var kind = new RadioButtons { Header = Strings.Get("Users/KindHeader"), MaxColumns = 2, SelectedIndex = 0 };
        kind.Items.Add(UsersNames.KindTitle(isRole: false));
        kind.Items.Add(UsersNames.KindTitle(isRole: true));
        if (features.RoleMembership)
        {
            panel.Children.Add(kind);
        }

        var name = new TextBox { Header = Strings.Get("Common/Name") };
        var host = new TextBox { Header = Strings.Get("Users/Host"), Text = "%", Description = Strings.Get("Users/HostDescription") };
        var password = new PasswordField(Strings.Get("Users/Password"));
        var problem = ErrorText();
        panel.Children.Add(name);
        if (features.HostScoping)
        {
            panel.Children.Add(host);
        }

        panel.Children.Add(password.Element);
        panel.Children.Add(problem);

        var dialog = dialogs.Create(Strings.Get("Users/NewPrincipalTitle"), panel, Strings.Get("Users/CreateButton"), Strings.Get("Common/Cancel"));
        bool IsRole() => features.RoleMembership && kind.SelectedIndex == 1;

        // A role never signs in, and on an engine without passwords (Typesense's API keys) no user does either.
        bool NeedsPassword() => features.Passwords && !IsRole();
        PrincipalRef Reference() => new(name.Text.Trim(), features.HostScoping ? host.Text.Trim() : null);

        void Validate()
        {
            password.Element.Visibility = NeedsPassword() ? Visibility.Visible : Visibility.Collapsed;
            var reference = Reference();
            string? error = null;
            if (reference.Name.Length > 0 && viewModel.IsNameTaken(reference))
            {
                error = Strings.Get("Users/NameTaken");
            }
            else if (features.HostScoping && reference.Host!.Length == 0)
            {
                error = Strings.Get("Users/HostRequired");
            }

            problem.Text = error ?? string.Empty;
            problem.Visibility = error is null ? Visibility.Collapsed : Visibility.Visible;
            dialog.IsPrimaryButtonEnabled = reference.Name.Length > 0 && error is null && (!NeedsPassword() || password.Value.Length > 0);
        }

        name.TextChanged += (_, _) => Validate();
        host.TextChanged += (_, _) => Validate();
        kind.SelectionChanged += (_, _) => Validate();
        password.Changed += Validate;
        name.Loaded += (_, _) => name.Focus(FocusState.Programmatic);
        Validate();

        if (await dialogs.ShowAsync(dialog) != ContentDialogResult.Primary)
        {
            return;
        }

        var isRole = IsRole();
        viewModel.Create(new PrincipalDefinition(Reference(), !NeedsPassword() || password.Value.Length == 0 ? null : password.Value, canLogin: !isRole));
    }

    public static async Task ChangePasswordAsync(DialogService dialogs, UsersRolesViewModel viewModel, PrincipalRef principal)
    {
        var password = new PasswordField(Strings.Get("Users/NewPassword"));
        var verify = new PasswordBox { Header = Strings.Get("Users/VerifyPassword") };
        var problem = ErrorText();
        var panel = new StackPanel { Spacing = 12, MinWidth = 400 };
        panel.Children.Add(new TextBlock { Text = principal.DisplayName, Style = (Style)Application.Current.Resources["BodyStrongTextBlockStyle"] });
        panel.Children.Add(password.Element);
        panel.Children.Add(verify);
        panel.Children.Add(problem);

        var dialog = dialogs.Create(Strings.Get("Users/ChangePasswordTitle"), panel, Strings.Get("Users/SetPasswordButton"), Strings.Get("Common/Cancel"));
        void Validate()
        {
            var mismatch = verify.Password.Length > 0 && verify.Password != password.Value;
            problem.Text = mismatch ? Strings.Get("Users/PasswordsDoNotMatch") : string.Empty;
            problem.Visibility = mismatch ? Visibility.Visible : Visibility.Collapsed;
            dialog.IsPrimaryButtonEnabled = password.Value.Length > 0 && password.Value == verify.Password;
        }

        password.Changed += Validate;
        password.Generated += generated => verify.Password = generated;
        verify.PasswordChanged += (_, _) => Validate();
        Validate();

        if (await dialogs.ShowAsync(dialog) == ContentDialogResult.Primary)
        {
            viewModel.SetPassword(principal, password.Value);
        }
    }

    public static async Task RenameAsync(DialogService dialogs, UsersRolesViewModel viewModel, PrincipalRef principal)
    {
        var current = viewModel.Tracker.Draft(principal)?.Ref ?? principal;
        var hostScoping = viewModel.Features.HostScoping;
        var name = new TextBox { Header = Strings.Get("Common/Name"), Text = current.Name };
        var host = new TextBox { Header = Strings.Get("Users/Host"), Text = current.Host ?? "%" };
        var problem = ErrorText();
        var panel = new StackPanel { Spacing = 12, MinWidth = 400 };
        panel.Children.Add(name);
        if (hostScoping)
        {
            panel.Children.Add(host);
        }

        panel.Children.Add(problem);
        var dialog = dialogs.Create(Strings.Format("Users/RenameTitle", principal.DisplayName), panel, Strings.Get("Common/Rename"), Strings.Get("Common/Cancel"));
        PrincipalRef Reference() => new(name.Text.Trim(), hostScoping ? host.Text.Trim() : null);

        void Validate()
        {
            var reference = Reference();
            var taken = reference != principal && viewModel.IsNameTaken(reference);
            problem.Text = taken ? Strings.Get("Users/NameTaken") : string.Empty;
            problem.Visibility = taken ? Visibility.Visible : Visibility.Collapsed;
            dialog.IsPrimaryButtonEnabled = reference.Name.Length > 0 && (!hostScoping || reference.Host!.Length > 0) && !taken && reference != current;
        }

        name.TextChanged += (_, _) => Validate();
        host.TextChanged += (_, _) => Validate();
        name.Loaded += (_, _) =>
        {
            name.Focus(FocusState.Programmatic);
            name.SelectAll();
        };
        Validate();

        if (await dialogs.ShowAsync(dialog) == ContentDialogResult.Primary)
        {
            viewModel.Rename(principal, Reference());
        }
    }

    public static async Task EditMembershipAsync(DialogService dialogs, UsersRolesViewModel viewModel, PrincipalRef principal)
    {
        var selected = new HashSet<string>(viewModel.Tracker.Draft(principal)?.MemberOf ?? [], StringComparer.Ordinal);
        var roles = viewModel.RoleCandidates(principal);
        var filter = new TextBox { PlaceholderText = Strings.Get("Users/FilterRoles") };
        var list = new StackPanel { Spacing = 2 };
        var panel = new StackPanel { Spacing = 8, MinWidth = 380 };
        panel.Children.Add(new TextBlock { Text = principal.DisplayName, Style = (Style)Application.Current.Resources["BodyStrongTextBlockStyle"] });
        panel.Children.Add(filter);
        panel.Children.Add(new ScrollViewer { Content = list, MaxHeight = 320 });

        void Fill()
        {
            list.Children.Clear();
            var text = filter.Text.Trim();
            foreach (var role in roles.Where(r => text.Length == 0 || r.Name.Contains(text, StringComparison.CurrentCultureIgnoreCase)))
            {
                var box = new CheckBox { Content = role.Name, IsChecked = selected.Contains(role.Name) };
                box.Click += (_, _) =>
                {
                    if (box.IsChecked == true)
                    {
                        selected.Add(role.Name);
                    }
                    else
                    {
                        selected.Remove(role.Name);
                    }
                };
                list.Children.Add(box);
            }

            if (list.Children.Count == 0)
            {
                list.Children.Add(new TextBlock { Text = roles.Count == 0 ? Strings.Get("Users/NoRolesToJoin") : Strings.Get("Users/NoRolesMatch") });
            }
        }

        filter.TextChanged += (_, _) => Fill();
        Fill();

        if (await dialogs.ShowAsync(dialogs.Create(Strings.Get("Users/MemberOf"), panel, Strings.Get("Common/Done"), Strings.Get("Common/Cancel"))) == ContentDialogResult.Primary)
        {
            viewModel.Edit(principal, d => d with { MemberOf = [.. selected.Order(StringComparer.Ordinal)] });
        }
    }

    public static async Task CopyPrivilegesAsync(DialogService dialogs, UsersRolesViewModel viewModel, PrincipalRef target)
    {
        var candidates = viewModel.Rows.Where(r => r.Ref != target).ToArray();
        var list = new ListView { SelectionMode = ListViewSelectionMode.Single, MaxHeight = 320, ItemsSource = candidates.Select(r => r.Title).ToArray() };
        var status = new TextBlock { Style = (Style)Application.Current.Resources["CaptionTextBlockStyle"] };
        var panel = new StackPanel { Spacing = 8, MinWidth = 380 };
        panel.Children.Add(new TextBlock { Text = Strings.Format("Users/CopyPrivilegesPrompt", target.DisplayName), TextWrapping = TextWrapping.Wrap });
        panel.Children.Add(list);
        panel.Children.Add(status);

        var dialog = dialogs.Create(Strings.Get("Users/CopyPrivilegesTitle"), panel, Strings.Get("Common/Copy"), Strings.Get("Common/Cancel"));
        dialog.IsPrimaryButtonEnabled = false;
        list.SelectionChanged += async (_, _) =>
        {
            dialog.IsPrimaryButtonEnabled = false;
            if (list.SelectedIndex < 0)
            {
                return;
            }

            var source = candidates[list.SelectedIndex].Ref;
            status.Text = Strings.Get("Users/LoadingPrivileges");
            try
            {
                await viewModel.EnsureGrantsAsync(source);
                status.Text = string.Empty;
                dialog.IsPrimaryButtonEnabled = list.SelectedIndex >= 0 && candidates[list.SelectedIndex].Ref == source;
            }
            catch (Exception ex) when (ex is not OperationCanceledException)
            {
                status.Text = ex.Message;
            }
        };

        if (await dialogs.ShowAsync(dialog) == ContentDialogResult.Primary && list.SelectedIndex >= 0)
        {
            viewModel.CopyPrivileges(candidates[list.SelectedIndex].Ref, target);
        }
    }

    /// <summary>
    /// PostgreSQL refuses to drop a role that owns objects until they are reassigned or dropped. Several roles dropped
    /// together are asked about once, and the choice applies to all of them.
    /// </summary>
    public static async Task<PrincipalDropOptions?> DropOwnedAsync(DialogService dialogs, UsersRolesViewModel viewModel, IReadOnlyList<PrincipalRef> owners)
    {
        var candidates = viewModel.ReassignCandidates(owners);
        var choice = new RadioButtons { SelectedIndex = candidates.Count > 0 ? 0 : 1 };
        choice.Items.Add(Strings.Get("Users/ReassignOwned"));
        choice.Items.Add(Strings.Get("Users/DropOwned"));
        var target = new ComboBox { Header = Strings.Get("Users/ReassignTo"),ItemsSource = candidates.Select(c => c.DisplayName).ToArray(), MinWidth = 240 };
        var connected = viewModel.ConnectedPrincipal is { } me ? candidates.ToList().IndexOf(me) : -1;
        target.SelectedIndex = connected >= 0 ? connected : candidates.Count > 0 ? 0 : -1;
        var warning = new TextBlock
        {
            Text = Strings.Get("Users/DropOwnedWarning"),
            TextWrapping = TextWrapping.Wrap,
            Style = (Style)Application.Current.Resources["CaptionTextBlockStyle"],
        };

        var panel = new StackPanel { Spacing = 12, MaxWidth = 460 };
        panel.Children.Add(new TextBlock { Text = Strings.Get("Users/DropOwnedPrompt"), TextWrapping = TextWrapping.Wrap });
        panel.Children.Add(choice);
        panel.Children.Add(target);
        panel.Children.Add(warning);

        var dialog = dialogs.Create(owners.Count == 1 ? Strings.Format("Users/OwnsObjectsTitle", owners[0].DisplayName) : Strings.Plural("Users/ManyOwnObjectsTitle", owners.Count), panel, Strings.Get("Users/DropRoleButton"), Strings.Get("Common/Cancel"));
        dialog.PrimaryButtonStyle = (Style)Application.Current.Resources["AccentButtonStyle"];
        void Update()
        {
            var reassign = choice.SelectedIndex == 0;
            target.IsEnabled = reassign;
            warning.Visibility = reassign ? Visibility.Collapsed : Visibility.Visible;
            dialog.IsPrimaryButtonEnabled = !reassign || target.SelectedIndex >= 0;
        }

        choice.SelectionChanged += (_, _) => Update();
        target.SelectionChanged += (_, _) => Update();
        Update();

        if (await dialogs.ShowAsync(dialog) != ContentDialogResult.Primary)
        {
            return null;
        }

        return choice.SelectedIndex == 0 ? new PrincipalDropOptions(candidates[target.SelectedIndex]) : new PrincipalDropOptions(DropOwned: true);
    }

    // The brush is looked up once the dialog is in the tree, when the text renders in the window's theme.
    private static TextBlock ErrorText()
    {
        var text = new TextBlock
        {
            Style = (Style)Application.Current.Resources["CaptionTextBlockStyle"],
            TextWrapping = TextWrapping.Wrap,
            Visibility = Visibility.Collapsed,
        };
        text.Loaded += (_, _) => text.Foreground = ThemeResources.Brush(text, "SystemFillColorCriticalBrush");
        return text;
    }

    /// <summary>A password box with a button that fills it with a generated password and shows it, so it can be copied.</summary>
    private sealed class PasswordField
    {
        private readonly PasswordBox _box;

        public PasswordField(string header)
        {
            _box = new PasswordBox { Header = header };
            var generate = new Button { Content = Strings.Get("Users/GenerateButton"),VerticalAlignment = VerticalAlignment.Bottom };
            generate.Click += (_, _) =>
            {
                var password = PasswordGenerator.Generate();
                _box.Password = password;
                _box.PasswordRevealMode = PasswordRevealMode.Visible;
                Generated?.Invoke(password);
            };
            _box.PasswordChanged += (_, _) => Changed?.Invoke();

            var grid = new Grid { ColumnSpacing = 8 };
            grid.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
            grid.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
            grid.Children.Add(_box);
            Grid.SetColumn(generate, 1);
            grid.Children.Add(generate);
            Element = grid;
        }

        public event Action? Changed;

        public event Action<string>? Generated;

        public FrameworkElement Element { get; }

        public string Value => _box.Password;
    }
}
