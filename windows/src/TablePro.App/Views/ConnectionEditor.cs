using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Media;
using TablePro.App.Helpers;
using TablePro.App.Services;
using TablePro.Core.Connections;

namespace TablePro.App.Views;

/// <summary>
/// The connection form, in the sections the macOS sheet has: General, SSL, SSH and Advanced. Test connects with what
/// is typed without saving; Save stores the profile and its secrets in Credential Manager.
/// </summary>
internal static class ConnectionEditor
{
    public static async Task<ConnectionProfile?> ShowAsync(DialogService dialogs, AppHost host, ConnectionProfile? existing)
    {
        var form = new Form(host, existing, dialogs);
        var dialog = dialogs.Create(existing is null ? "New Connection" : $"Edit {existing.Name}", form.Root, "Save", "Cancel", "Test");
        dialog.IsPrimaryButtonEnabled = true;
        dialog.PrimaryButtonClick += (_, args) =>
        {
            if (form.Validate() is { } problem)
            {
                form.ShowStatus(problem, InfoBarSeverity.Error);
                args.Cancel = true;
            }
        };
        dialog.SecondaryButtonClick += async (_, args) =>
        {
            args.Cancel = true;
            var deferral = args.GetDeferral();
            try
            {
                if (form.Validate() is { } problem)
                {
                    form.ShowStatus(problem, InfoBarSeverity.Error);
                    return;
                }

                form.ShowStatus("Testing…", InfoBarSeverity.Informational);
                using var timeout = new CancellationTokenSource(TimeSpan.FromSeconds(30));
                var profile = form.Build();
                var savedSsh = host.Connector.SavedSshSecret(profile);
                form.StoreSshSecretForTest(host.Connector, profile);
                try
                {
                    var message = await host.Connector.TestAsync(profile, form.Password, timeout.Token);
                    form.ShowStatus(message, InfoBarSeverity.Success);
                }
                finally
                {
                    if (existing is null)
                    {
                        host.Connector.SaveSshSecret(profile, savedSsh);
                    }
                }
            }
            catch (Exception ex)
            {
                form.ShowStatus(ex.Message, InfoBarSeverity.Error);
            }
            finally
            {
                deferral.Complete();
            }
        };

        if (await dialogs.ShowAsync(dialog) != ContentDialogResult.Primary)
        {
            return null;
        }

        var saved = form.Build();
        host.Connector.SavePassword(saved, form.Password);
        if (form.SshSecret is { Length: > 0 } secret || saved.Ssh is not { Enabled: true })
        {
            host.Connector.SaveSshSecret(saved, saved.Ssh is { Enabled: true } ? form.SshSecret : null);
        }

        await host.Connections.UpsertAsync(saved);
        return saved;
    }

    private sealed class Form
    {
        private readonly AppHost _host;
        private readonly ConnectionProfile? _existing;
        private readonly DialogService _dialogs;
        private readonly TextBox _name = new() { Header = "Name", PlaceholderText = "Production" };
        private readonly ComboBox _engine = new() { Header = "Database", HorizontalAlignment = HorizontalAlignment.Stretch };
        private readonly TextBox _host_ = new() { Header = "Host", PlaceholderText = "localhost" };
        private readonly NumberBox _port = new() { Header = "Port", SpinButtonPlacementMode = NumberBoxSpinButtonPlacementMode.Hidden, Minimum = 0, Maximum = 65535, Width = 110 };
        private readonly TextBox _user = new() { Header = "User" };
        private readonly PasswordBox _password = new() { Header = "Password" };
        private readonly CheckBox _savePassword = new() { Content = "Save password in Windows Credential Manager", IsChecked = true };
        private readonly TextBox _database = new() { Header = "Database", PlaceholderText = "Optional" };
        private readonly TextBox _file = new() { Header = "File", PlaceholderText = "C:\\data\\app.sqlite" };
        private readonly Button _browse = new() { Content = "Browse…", VerticalAlignment = VerticalAlignment.Bottom };
        private readonly ComboBox _group = new() { Header = "Group", HorizontalAlignment = HorizontalAlignment.Stretch };
        private readonly StackPanel _colors = new() { Orientation = Orientation.Horizontal, Spacing = 6 };
        private readonly ComboBox _ssl = new() { Header = "SSL mode", HorizontalAlignment = HorizontalAlignment.Stretch };
        private readonly ToggleSwitch _sshEnabled = new() { Header = "Connect through an SSH tunnel" };
        private readonly TextBox _sshHost = new() { Header = "SSH host" };
        private readonly NumberBox _sshPort = new() { Header = "Port", Value = 22, SpinButtonPlacementMode = NumberBoxSpinButtonPlacementMode.Hidden, Width = 110 };
        private readonly TextBox _sshUser = new() { Header = "SSH user" };
        private readonly ComboBox _sshAuth = new() { Header = "Authentication", HorizontalAlignment = HorizontalAlignment.Stretch };
        private readonly TextBox _sshKey = new() { Header = "Private key", PlaceholderText = "%USERPROFILE%\\.ssh\\id_ed25519" };
        private readonly PasswordBox _sshSecret = new() { Header = "Password or key passphrase" };
        private readonly TextBox _jump = new() { Header = "Jump hosts", PlaceholderText = "user@bastion:22, optional" };
        private readonly ComboBox _safeMode = new() { Header = "Safe Mode", HorizontalAlignment = HorizontalAlignment.Stretch };
        private readonly ComboBox _ai = new() { Header = "AI assistant", HorizontalAlignment = HorizontalAlignment.Stretch };
        private readonly ComboBox _mcp = new() { Header = "External clients (MCP)", HorizontalAlignment = HorizontalAlignment.Stretch };
        private readonly NumberBox _timeout = new() { Header = "Connect timeout (seconds)", Minimum = 1, Maximum = 600, SpinButtonPlacementMode = NumberBoxSpinButtonPlacementMode.Compact };
        private readonly TextBox _startup = new() { Header = "Run on connect", AcceptsReturn = true, Height = 96, PlaceholderText = "SET search_path TO app, public;" };
        private readonly TextBox _options = new() { Header = "Extra connection string options", AcceptsReturn = true, Height = 96, PlaceholderText = "one key=value per line" };
        private readonly InfoBar _status = new() { IsClosable = false, IsOpen = false };
        private readonly StackPanel _network = new() { Spacing = 12 };
        private readonly Grid _fileRow = new() { ColumnSpacing = 8 };
        private readonly StackPanel _sshFields = new() { Spacing = 12 };
        private readonly EngineDescriptor[] _engines;
        private ConnectionColor _color;

        public Form(AppHost host, ConnectionProfile? existing, DialogService dialogs)
        {
            _host = host;
            _dialogs = dialogs;

            // Only engines this build has a driver for, grouped by family as tablepro.app lists them.
            _engines = EngineDescriptor.Engines.Where(d => host.Connector.Drivers.Supports(d.Engine)).ToArray();
            _existing = existing;
            Root = Build(out var sections);
            Fill(existing);
            sections.SelectedItem = sections.Items[0];
        }

        public FrameworkElement Root { get; }

        public string? Password => string.IsNullOrEmpty(_password.Password) ? null : _password.Password;

        public string? SshSecret => string.IsNullOrEmpty(_sshSecret.Password) ? null : _sshSecret.Password;

        public void ShowStatus(string message, InfoBarSeverity severity)
        {
            _status.Message = message;
            _status.Severity = severity;
            _status.IsOpen = true;
        }

        public string? Validate()
        {
            var descriptor = SelectedDescriptor;
            if (string.IsNullOrWhiteSpace(_name.Text))
            {
                return "Give the connection a name.";
            }

            if (descriptor.IsFileBased && string.IsNullOrWhiteSpace(_file.Text))
            {
                return "Choose a database file.";
            }

            if (!descriptor.IsFileBased && string.IsNullOrWhiteSpace(_host_.Text))
            {
                return "Enter the server's host name.";
            }

            if (_sshEnabled.IsOn && string.IsNullOrWhiteSpace(_sshHost.Text))
            {
                return "Enter the SSH host, or turn the tunnel off.";
            }

            return null;
        }

        /// <summary>The test connects before anything is saved, so a typed SSH secret is stored under the profile id briefly.</summary>
        public void StoreSshSecretForTest(ConnectionService connector, ConnectionProfile profile)
        {
            if (SshSecret is { } secret)
            {
                connector.SaveSshSecret(profile, secret);
            }
        }

        public ConnectionProfile Build()
        {
            var descriptor = SelectedDescriptor;
            var options = _options.Text.Split(['\r', '\n'], StringSplitOptions.RemoveEmptyEntries | StringSplitOptions.TrimEntries)
                .Select(line => line.Split('=', 2))
                .Where(parts => parts.Length == 2 && parts[0].Trim().Length > 0)
                .ToDictionary(parts => parts[0].Trim(), parts => parts[1].Trim(), StringComparer.OrdinalIgnoreCase);
            var groups = _host.Connections.Groups;
            return (_existing ?? new ConnectionProfile { Name = string.Empty, Engine = descriptor.Engine }) with
            {
                Name = _name.Text.Trim(),
                Engine = descriptor.Engine,
                Host = descriptor.IsFileBased ? "localhost" : _host_.Text.Trim(),
                Port = descriptor.IsFileBased || double.IsNaN(_port.Value) ? 0 : (int)_port.Value,
                Username = string.IsNullOrWhiteSpace(_user.Text) ? null : _user.Text.Trim(),
                Database = string.IsNullOrWhiteSpace(_database.Text) ? null : _database.Text.Trim(),
                FilePath = descriptor.IsFileBased || EngineForm.For(descriptor.Engine).FileLabel is not null
                    ? NullIfEmpty(Environment.ExpandEnvironmentVariables(_file.Text.Trim()))
                    : null,
                SavePassword = _savePassword.IsChecked == true,
                SslMode = (SslMode)Math.Max(0, _ssl.SelectedIndex),
                SafeMode = (SafeModeLevel)Math.Max(0, _safeMode.SelectedIndex),
                AiPolicy = (AiPolicy)Math.Max(0, _ai.SelectedIndex),
                ExternalAccess = (ExternalAccessLevel)Math.Max(0, _mcp.SelectedIndex),
                Color = _color,
                Group = _group.SelectedIndex > 0 ? groups[_group.SelectedIndex - 1].Key : null,
                ConnectTimeoutSeconds = double.IsNaN(_timeout.Value) ? 15 : (int)_timeout.Value,
                StartupCommands = string.IsNullOrWhiteSpace(_startup.Text) ? null : _startup.Text,
                AdditionalOptions = options,
                Ssh = !_sshEnabled.IsOn && _existing?.Ssh is null ? null : new SshTunnelSettings
                {
                    Enabled = _sshEnabled.IsOn,
                    Host = _sshHost.Text.Trim(),
                    Port = double.IsNaN(_sshPort.Value) ? 22 : (int)_sshPort.Value,
                    Username = string.IsNullOrWhiteSpace(_sshUser.Text) ? null : _sshUser.Text.Trim(),
                    AuthMethod = (SshAuthMethod)Math.Max(0, _sshAuth.SelectedIndex),
                    PrivateKeyPath = string.IsNullOrWhiteSpace(_sshKey.Text) ? null : Environment.ExpandEnvironmentVariables(_sshKey.Text.Trim()),
                    JumpHosts = string.IsNullOrWhiteSpace(_jump.Text) ? null : _jump.Text.Trim(),
                },
            };
        }

        private EngineDescriptor SelectedDescriptor => _engines[Math.Max(0, _engine.SelectedIndex)];

        private FrameworkElement Build(out SelectorBar sections)
        {
            foreach (var engine in _engines)
            {
                _engine.Items.Add(engine.QueryLanguage is "SQL" ? engine.DisplayName : $"{engine.DisplayName}  ({engine.QueryLanguage})");
            }

            foreach (var mode in new[] { "Disabled", "Preferred", "Required (skip verify)", "Verify CA", "Verify identity" })
            {
                _ssl.Items.Add(mode);
            }

            foreach (var level in new[] { "Silent", "Alert", "Alert (Full)", "Safe Mode", "Safe Mode (Full)", "Read-Only" })
            {
                _safeMode.Items.Add(level);
            }

            foreach (var policy in new[] { "Ask each time", "Allow", "Never" })
            {
                _ai.Items.Add(policy);
            }

            foreach (var access in new[] { "Blocked", "Read only", "Read and write, each write approved" })
            {
                _mcp.Items.Add(access);
            }

            foreach (var method in new[] { "SSH agent", "Private key", "Password" })
            {
                _sshAuth.Items.Add(method);
            }

            _group.Items.Add("No group");
            foreach (var group in _host.Connections.Groups)
            {
                _group.Items.Add(group.Name);
            }

            foreach (var color in Enum.GetValues<ConnectionColor>())
            {
                var swatch = new RadioButton
                {
                    GroupName = "connection-color",
                    Tag = color,
                    MinWidth = 0,
                    Padding = new Thickness(0),
                    Content = new Microsoft.UI.Xaml.Shapes.Ellipse
                    {
                        Width = 18,
                        Height = 18,
                        Fill = color == ConnectionColor.None ? new SolidColorBrush(Microsoft.UI.Colors.Transparent) : ConnectionColors.Brush(color),
                        Stroke = (Brush)Application.Current.Resources["ControlStrongStrokeColorDefaultBrush"],
                        StrokeThickness = color == ConnectionColor.None ? 1 : 0,
                    },
                };
                ToolTipService.SetToolTip(swatch, color.ToString());
                swatch.Checked += (_, _) => _color = color;
                _colors.Children.Add(swatch);
            }

            _engine.SelectionChanged += (_, _) => OnEngineChanged();
            _sshEnabled.Toggled += (_, _) => _sshFields.Visibility = _sshEnabled.IsOn ? Visibility.Visible : Visibility.Collapsed;
            _sshAuth.SelectionChanged += (_, _) => _sshKey.Visibility = _sshAuth.SelectedIndex == 1 ? Visibility.Visible : Visibility.Collapsed;
            _browse.Click += async (_, _) =>
            {
                var file = SelectedDescriptor.IsFileBased
                    ? await _dialogs.PickOpenFileAsync(".sqlite", ".sqlite3", ".db", ".db3", ".duckdb", ".ddb", ".beancount", "*")
                    : await _dialogs.PickOpenFileAsync(".json", ".p8", ".pem", "*");
                if (file is not null)
                {
                    _file.Text = file.Path;
                    if (string.IsNullOrWhiteSpace(_name.Text) && SelectedDescriptor.IsFileBased)
                    {
                        _name.Text = Path.GetFileNameWithoutExtension(file.Path);
                    }
                }
            };

            var hostRow = new Grid { ColumnSpacing = 8 };
            hostRow.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
            hostRow.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
            hostRow.Children.Add(_host_);
            Grid.SetColumn(_port, 1);
            hostRow.Children.Add(_port);
            _network.Children.Add(hostRow);
            _network.Children.Add(_user);
            _network.Children.Add(_password);
            _network.Children.Add(_savePassword);
            _network.Children.Add(_database);

            _fileRow.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
            _fileRow.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
            _fileRow.Children.Add(_file);
            Grid.SetColumn(_browse, 1);
            _fileRow.Children.Add(_browse);

            var general = Section(_name, _engine, _network, _fileRow, _group, Labeled("Color", _colors));

            var ssl = Section(_ssl, Note("Preferred encrypts when the server offers it. The Verify modes check the server's certificate against the Windows certificate store, and Verify identity also checks the host name."));

            var sshHostRow = new Grid { ColumnSpacing = 8 };
            sshHostRow.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
            sshHostRow.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
            sshHostRow.Children.Add(_sshHost);
            Grid.SetColumn(_sshPort, 1);
            sshHostRow.Children.Add(_sshPort);
            _sshFields.Children.Add(sshHostRow);
            _sshFields.Children.Add(_sshUser);
            _sshFields.Children.Add(_sshAuth);
            _sshFields.Children.Add(_sshKey);
            _sshFields.Children.Add(_sshSecret);
            _sshFields.Children.Add(_jump);
            var ssh = Section(_sshEnabled, _sshFields, Note("TablePro runs the OpenSSH client that ships with Windows, so your ~/.ssh/config, known_hosts and agent apply."));

            var advanced = Section(_safeMode, _ai, _mcp, _timeout, _startup, _options);

            var pages = new Dictionary<string, FrameworkElement> { ["General"] = general, ["SSL"] = ssl, ["SSH"] = ssh, ["Advanced"] = advanced };
            var host = new ContentControl { HorizontalContentAlignment = HorizontalAlignment.Stretch };
            sections = new SelectorBar();
            foreach (var name in pages.Keys)
            {
                sections.Items.Add(new SelectorBarItem { Text = name, Tag = name });
            }

            sections.SelectionChanged += (bar, _) => host.Content = pages[(string)bar.SelectedItem.Tag];

            var root = new StackPanel { Spacing = 12, Width = 480 };
            root.Children.Add(sections);
            root.Children.Add(new ScrollViewer { Content = host, MaxHeight = 460, Padding = new Thickness(0, 0, 12, 0) });
            root.Children.Add(_status);
            return root;
        }

        private void Fill(ConnectionProfile? profile)
        {
            var p = profile ?? new ConnectionProfile { Name = string.Empty, Engine = DatabaseEngine.PostgreSql };
            _name.Text = p.Name;
            _engine.SelectedIndex = Math.Max(0, Array.FindIndex(_engines, d => d.Engine == p.Engine));
            _host_.Text = p.Host;
            _port.Value = p.Port > 0 ? p.Port : p.Descriptor.DefaultPort;
            _user.Text = p.Username ?? (profile is null ? p.Descriptor.DefaultUser : string.Empty);
            _password.Password = profile is null ? string.Empty : _host.Connector.SavedPassword(p) ?? string.Empty;
            _savePassword.IsChecked = p.SavePassword;
            _database.Text = p.Database ?? string.Empty;
            _file.Text = p.FilePath ?? string.Empty;
            _ssl.SelectedIndex = (int)p.SslMode;
            _safeMode.SelectedIndex = (int)p.SafeMode;
            _ai.SelectedIndex = (int)p.AiPolicy;
            _mcp.SelectedIndex = (int)p.ExternalAccess;
            _timeout.Value = p.ConnectTimeoutSeconds;
            _startup.Text = p.StartupCommands ?? string.Empty;
            _options.Text = string.Join("\n", p.AdditionalOptions.Select(o => $"{o.Key}={o.Value}"));
            var groupIndex = _host.Connections.Groups.ToList().FindIndex(g => g.Key == p.Group);
            _group.SelectedIndex = groupIndex + 1;
            _color = p.Color;
            foreach (var swatch in _colors.Children.OfType<RadioButton>())
            {
                swatch.IsChecked = (ConnectionColor)swatch.Tag == p.Color;
            }

            var ssh = p.Ssh ?? new SshTunnelSettings();
            _sshEnabled.IsOn = ssh.Enabled;
            _sshHost.Text = ssh.Host;
            _sshPort.Value = ssh.Port;
            _sshUser.Text = ssh.Username ?? string.Empty;
            _sshAuth.SelectedIndex = (int)ssh.AuthMethod;
            _sshKey.Text = ssh.PrivateKeyPath ?? string.Empty;
            _sshKey.Visibility = ssh.AuthMethod == SshAuthMethod.PrivateKey ? Visibility.Visible : Visibility.Collapsed;
            _jump.Text = ssh.JumpHosts ?? string.Empty;
            _sshFields.Visibility = ssh.Enabled ? Visibility.Visible : Visibility.Collapsed;
            OnEngineChanged();
        }

        private void OnEngineChanged()
        {
            var descriptor = SelectedDescriptor;
            var form = EngineForm.For(descriptor.Engine);
            _network.Visibility = descriptor.IsFileBased ? Visibility.Collapsed : Visibility.Visible;
            _fileRow.Visibility = descriptor.IsFileBased || form.FileLabel is not null ? Visibility.Visible : Visibility.Collapsed;
            _file.Header = form.FileLabel ?? "File";
            _host_.Header = form.HostLabel;
            _host_.PlaceholderText = form.HostPlaceholder;
            _port.Visibility = form.ShowPort ? Visibility.Visible : Visibility.Collapsed;
            _user.Visibility = form.ShowUser ? Visibility.Visible : Visibility.Collapsed;
            _user.Header = form.UserLabel;
            _password.Header = form.PasswordLabel;
            _database.Header = form.DatabaseLabel;
            _options.PlaceholderText = form.OptionsHint ?? "one key=value per line";
            if (_existing is null || _existing.Engine != descriptor.Engine)
            {
                _port.Value = descriptor.DefaultPort;
                if (string.IsNullOrWhiteSpace(_user.Text) || EngineDescriptor.Engines.Any(d => d.DefaultUser == _user.Text))
                {
                    _user.Text = descriptor.DefaultUser;
                }
            }
        }

        private static string? NullIfEmpty(string text) => string.IsNullOrWhiteSpace(text) ? null : text;

        private static StackPanel Section(params UIElement[] children)
        {
            var panel = new StackPanel { Spacing = 12, Padding = new Thickness(0, 4, 0, 4) };
            foreach (var child in children)
            {
                panel.Children.Add(child);
            }

            return panel;
        }

        private static StackPanel Labeled(string label, UIElement content)
        {
            var panel = new StackPanel { Spacing = 6 };
            panel.Children.Add(new TextBlock { Text = label });
            panel.Children.Add(content);
            return panel;
        }

        private static TextBlock Note(string text) => new()
        {
            Text = text,
            TextWrapping = TextWrapping.Wrap,
            Style = (Style)Application.Current.Resources["CaptionTextBlockStyle"],
            Foreground = (Brush)Application.Current.Resources["TextFillColorSecondaryBrush"],
        };
    }
}
