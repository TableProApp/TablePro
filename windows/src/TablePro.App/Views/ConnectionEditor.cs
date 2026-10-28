using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Media;
using TablePro.App.Helpers;
using TablePro.App.Services;
using TablePro.Core.Connections;

namespace TablePro.App.Views;

/// <summary>
/// The connection form, in the sections the macOS sheet has: General, SSL, Network and Advanced. Test connects with
/// what is typed without saving; Save stores the profile and its secrets in Credential Manager.
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
                using var timeout = new CancellationTokenSource(TimeSpan.FromSeconds(60));
                var profile = form.Build();
                var restore = form.StoreSecretsForTest(host.Connector, profile);
                try
                {
                    var message = await host.Connector.TestAsync(profile, form.Password, timeout.Token);
                    form.ShowStatus(message, InfoBarSeverity.Success);
                }
                finally
                {
                    if (existing is null)
                    {
                        restore();
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
        host.Connector.SavePassword(saved, saved.UsesSecret() ? form.Password : null);
        if (form.SshSecret is { Length: > 0 } secret || saved.Ssh is not { Enabled: true })
        {
            host.Connector.SaveSshSecret(saved, saved.Ssh is { Enabled: true } ? form.SshSecret : null);
        }

        form.SaveTransportSecrets(host.Connector, saved);
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
        private readonly ComboBox _auth = new() { Header = "Authentication", HorizontalAlignment = HorizontalAlignment.Stretch };
        private readonly TextBox _user = new() { Header = "User" };
        private readonly PasswordBox _password = new() { Header = "Password" };
        private readonly CheckBox _savePassword = new() { Content = "Save password in Windows Credential Manager", IsChecked = true };
        private readonly TextBox _database = new() { Header = "Database", PlaceholderText = "Optional" };
        private readonly TextBox _file = new() { Header = "File", PlaceholderText = "C:\\data\\app.sqlite" };
        private readonly Button _browse = new() { Content = "Browse…", VerticalAlignment = VerticalAlignment.Bottom };
        private readonly ComboBox _group = new() { Header = "Group", HorizontalAlignment = HorizontalAlignment.Stretch };
        private readonly StackPanel _colors = new() { Orientation = Orientation.Horizontal, Spacing = 6 };
        private readonly ComboBox _ssl = new() { Header = "SSL mode", HorizontalAlignment = HorizontalAlignment.Stretch };

        // Sign-in fields beyond user and password.
        private readonly StackPanel _awsFields = new() { Spacing = 12 };
        private readonly TextBox _awsRegion = new() { Header = "AWS region", PlaceholderText = "Read from the RDS host name when empty" };
        private readonly TextBox _awsAccessKey = new() { Header = "Access key ID", PlaceholderText = "AKIA..." };
        private readonly TextBox _awsProfile = new() { Header = "Profile name", PlaceholderText = "default" };
        private readonly TextBox _awsEndpoint = new() { Header = "RDS endpoint (optional)", PlaceholderText = "mydb.abc123.us-east-1.rds.amazonaws.com:5432" };
        private readonly StackPanel _entraFields = new() { Spacing = 12 };
        private readonly ComboBox _entraMode = new() { Header = "Entra credential", HorizontalAlignment = HorizontalAlignment.Stretch };
        private readonly TextBox _entraTenant = new() { Header = "Directory (tenant) ID", PlaceholderText = "Optional, for a single-tenant directory" };
        private readonly TextBox _entraClient = new() { Header = "Application (client) ID", PlaceholderText = "00000000-0000-0000-0000-000000000000" };
        private readonly StackPanel _kerberosFields = new() { Spacing = 12 };
        private readonly TextBox _kerberosService = new() { Header = "Kerberos service name" };
        private readonly ComboBox _gssEncryption = new() { Header = "GSS encryption", HorizontalAlignment = HorizontalAlignment.Stretch };
        private readonly TextBlock _authNote = Note(string.Empty);

        // Network page.
        private readonly ComboBox _transport = new() { Header = "Connect via", HorizontalAlignment = HorizontalAlignment.Stretch };
        private readonly TextBlock _transportNote = Note(string.Empty);
        private readonly StackPanel _sshFields = new() { Spacing = 12 };
        private readonly TextBox _sshHost = new() { Header = "SSH host" };
        private readonly NumberBox _sshPort = new() { Header = "Port", Value = 22, SpinButtonPlacementMode = NumberBoxSpinButtonPlacementMode.Hidden, Width = 110 };
        private readonly TextBox _sshUser = new() { Header = "SSH user" };
        private readonly ComboBox _sshAuth = new() { Header = "Authentication", HorizontalAlignment = HorizontalAlignment.Stretch };
        private readonly TextBox _sshKey = new() { Header = "Private key", PlaceholderText = "%USERPROFILE%\\.ssh\\id_ed25519" };
        private readonly PasswordBox _sshSecret = new() { Header = "Password or key passphrase" };
        private readonly TextBox _jump = new() { Header = "Jump hosts", PlaceholderText = "user@bastion:22, optional" };

        private readonly StackPanel _proxyFields = new() { Spacing = 12 };
        private readonly ComboBox _proxyProtocol = new() { Header = "Proxy type", HorizontalAlignment = HorizontalAlignment.Stretch };
        private readonly TextBox _proxyHost = new() { Header = "Proxy host", PlaceholderText = "proxy.example.com" };
        private readonly NumberBox _proxyPort = new() { Header = "Port", Value = 1080, SpinButtonPlacementMode = NumberBoxSpinButtonPlacementMode.Hidden, Minimum = 1, Maximum = 65535, Width = 110 };
        private readonly TextBox _proxyUser = new() { Header = "Proxy user", PlaceholderText = "Optional" };
        private readonly PasswordBox _proxyPassword = new() { Header = "Proxy password" };

        private readonly StackPanel _cloudSqlFields = new() { Spacing = 12 };
        private readonly TextBox _cloudSqlInstance = new() { Header = "Instance connection name", PlaceholderText = "project:region:instance" };
        private readonly ComboBox _cloudSqlAuth = new() { Header = "Credentials", HorizontalAlignment = HorizontalAlignment.Stretch };
        private readonly TextBox _cloudSqlKey = new() { Header = "Service account key (JSON)", AcceptsReturn = true, Height = 96, TextWrapping = TextWrapping.Wrap };
        private readonly TextBlock _cloudSqlAdcNote = Note("Run \u201Cgcloud auth application-default login\u201D first, or set GOOGLE_APPLICATION_CREDENTIALS.");
        private readonly CheckBox _cloudSqlIam = new() { Content = "Use IAM database authentication" };
        private readonly CheckBox _cloudSqlPrivateIp = new() { Content = "Connect over private IP" };
        private readonly NumberBox _cloudSqlPort = new() { Header = "Local port", PlaceholderText = "Automatic", SpinButtonPlacementMode = NumberBoxSpinButtonPlacementMode.Hidden, Minimum = 1, Maximum = 65535 };
        private readonly TextBox _cloudSqlPath = new() { Header = "cloud-sql-proxy.exe", PlaceholderText = "Automatic" };

        private readonly StackPanel _cloudflareFields = new() { Spacing = 12 };
        private readonly TextBox _cloudflareHost = new() { Header = "Access application hostname", PlaceholderText = "db.example.com" };
        private readonly ComboBox _cloudflareAuth = new() { Header = "Method", HorizontalAlignment = HorizontalAlignment.Stretch };
        private readonly Button _cloudflareSignIn = new() { Content = "Sign in with browser…" };
        private readonly PasswordBox _cloudflareTokenId = new() { Header = "Client ID" };
        private readonly PasswordBox _cloudflareTokenSecret = new() { Header = "Client secret" };
        private readonly NumberBox _cloudflarePort = new() { Header = "Local port", PlaceholderText = "Automatic", SpinButtonPlacementMode = NumberBoxSpinButtonPlacementMode.Hidden, Minimum = 1, Maximum = 65535 };
        private readonly CheckBox _cloudflareLan = new() { Content = "Expose to the local network (listen on 0.0.0.0)" };
        private readonly TextBox _cloudflarePath = new() { Header = "cloudflared.exe", PlaceholderText = "Automatic" };

        private readonly StackPanel _commandFields = new() { Spacing = 12 };
        private readonly ComboBox _commandMethod = new() { Header = "Method", HorizontalAlignment = HorizontalAlignment.Stretch };
        private readonly StackPanel _kubectlFields = new() { Spacing = 12 };
        private readonly TextBox _kubeResource = new() { Header = "Resource", PlaceholderText = "service/postgres" };
        private readonly TextBox _kubeNamespace = new() { Header = "Namespace", PlaceholderText = "Optional" };
        private readonly TextBox _kubeContext = new() { Header = "Context", PlaceholderText = "Optional" };
        private readonly StackPanel _ssmFields = new() { Spacing = 12 };
        private readonly TextBox _ssmTarget = new() { Header = "Target", PlaceholderText = "i-0123456789abcdef0" };
        private readonly TextBox _ssmProfile = new() { Header = "Profile", PlaceholderText = "Optional" };
        private readonly TextBox _ssmRegion = new() { Header = "Region", PlaceholderText = "Optional" };
        private readonly TextBox _commandPath = new() { Header = "Executable path", PlaceholderText = "Found on PATH when empty" };
        private readonly TextBox _command = new()
        {
            Header = "Command",
            AcceptsReturn = true,
            Height = 72,
            TextWrapping = TextWrapping.Wrap,
            PlaceholderText = "ssh -N -L {port}:{host}:{remotePort} bastion",
            FontFamily = new FontFamily("Cascadia Mono, Consolas"),
        };

        private readonly TextBlock _commandPreview = new() { TextWrapping = TextWrapping.Wrap, IsTextSelectionEnabled = true, FontFamily = new FontFamily("Cascadia Mono, Consolas") };

        private readonly ComboBox _safeMode = new() { Header = "Safe Mode", HorizontalAlignment = HorizontalAlignment.Stretch };
        private readonly ComboBox _ai = new() { Header = "AI assistant", HorizontalAlignment = HorizontalAlignment.Stretch };
        private readonly ComboBox _mcp = new() { Header = "External clients (MCP)", HorizontalAlignment = HorizontalAlignment.Stretch };
        private readonly NumberBox _timeout = new() { Header = "Connect timeout (seconds)", Minimum = 1, Maximum = 600, SpinButtonPlacementMode = NumberBoxSpinButtonPlacementMode.Compact };
        private readonly TextBox _startup = new() { Header = "Run on connect", AcceptsReturn = true, Height = 96, PlaceholderText = "SET search_path TO app, public;" };
        private readonly TextBox _options = new() { Header = "Extra connection string options", AcceptsReturn = true, Height = 96, PlaceholderText = "one key=value per line" };
        private readonly InfoBar _status = new() { IsClosable = false, IsOpen = false };
        private readonly StackPanel _network = new() { Spacing = 12 };
        private readonly Grid _fileRow = new() { ColumnSpacing = 8 };
        private readonly EngineDescriptor[] _engines;
        private IReadOnlyList<SignInMethod> _authChoices = [SignInMethod.Password];
        private IReadOnlyList<EntraAuthMode> _entraChoices = [];
        private IReadOnlyList<ConnectionTransport> _transportChoices = [ConnectionTransport.Direct];
        private ConnectionColor _color;
        private bool _filling;

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

        private EngineDescriptor SelectedDescriptor => _engines[Math.Max(0, _engine.SelectedIndex)];

        private SignInMethod SelectedSignIn => _authChoices[Math.Clamp(_auth.SelectedIndex, 0, _authChoices.Count - 1)];

        private EntraAuthMode SelectedEntraMode => _entraChoices.Count == 0 ? EntraAuthMode.Interactive : _entraChoices[Math.Clamp(_entraMode.SelectedIndex, 0, _entraChoices.Count - 1)];

        private ConnectionTransport SelectedTransport => _transportChoices[Math.Clamp(_transport.SelectedIndex, 0, _transportChoices.Count - 1)];

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

            var profile = Build();
            if (profile.Validate() is { } transportProblem)
            {
                return transportProblem;
            }

            return SignInProblem(profile);
        }

        /// <summary>
        /// The test connects before anything is saved, so the typed SSH and transport secrets are stored under the
        /// profile id for its length. The returned action puts back what was stored before.
        /// </summary>
        public Action StoreSecretsForTest(ConnectionService connector, ConnectionProfile profile)
        {
            var savedSsh = connector.SavedSshSecret(profile);
            var savedTransport = Enum.GetValues<TransportSecret>().ToDictionary(s => s, s => connector.SavedTransportSecret(profile, s));
            if (SshSecret is { } secret)
            {
                connector.SaveSshSecret(profile, secret);
            }

            SaveTransportSecrets(connector, profile);
            return () =>
            {
                connector.SaveSshSecret(profile, savedSsh);
                foreach (var (kind, value) in savedTransport)
                {
                    connector.SaveTransportSecret(profile, kind, value);
                }
            };
        }

        /// <summary>Stores the secrets of the transport in use and drops the ones a transport turned off no longer needs.</summary>
        public void SaveTransportSecrets(ConnectionService connector, ConnectionProfile profile)
        {
            var transport = profile.ActiveTransport();
            connector.SaveTransportSecret(profile, TransportSecret.ProxyPassword, transport == ConnectionTransport.Proxy && !string.IsNullOrEmpty(profile.Proxy?.Username) ? _proxyPassword.Password : null);
            connector.SaveTransportSecret(profile, TransportSecret.CloudSqlServiceAccountKey, transport == ConnectionTransport.CloudSqlProxy && profile.CloudSqlProxy!.AuthMode == CloudSqlAuthMode.ServiceAccountKey ? _cloudSqlKey.Text.Trim() : null);
            var token = transport == ConnectionTransport.CloudflareTunnel && profile.CloudflareTunnel!.AuthMethod == CloudflareAuthMethod.ServiceToken;
            connector.SaveTransportSecret(profile, TransportSecret.CloudflareTokenId, token ? _cloudflareTokenId.Password : null);
            connector.SaveTransportSecret(profile, TransportSecret.CloudflareTokenSecret, token ? _cloudflareTokenSecret.Password : null);
        }

        public ConnectionProfile Build()
        {
            var descriptor = SelectedDescriptor;
            var options = _options.Text.Split(['\r', '\n'], StringSplitOptions.RemoveEmptyEntries | StringSplitOptions.TrimEntries)
                .Select(line => line.Split('=', 2))
                .Where(parts => parts.Length == 2 && parts[0].Trim().Length > 0)
                .ToDictionary(parts => parts[0].Trim(), parts => parts[1].Trim(), StringComparer.OrdinalIgnoreCase);
            var groups = _host.Connections.Groups;
            var transport = descriptor.IsFileBased ? ConnectionTransport.Direct : SelectedTransport;
            var profile = (_existing ?? new ConnectionProfile { Name = string.Empty, Engine = descriptor.Engine }) with
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
                Auth = BuildAuth(),

                // A transport's settings are kept, turned off, once something was typed, so switching back restores them.
                Ssh = Keep(_existing?.Ssh, transport == ConnectionTransport.Ssh, !string.IsNullOrWhiteSpace(_sshHost.Text), on => new SshTunnelSettings
                {
                    Enabled = on,
                    Host = _sshHost.Text.Trim(),
                    Port = double.IsNaN(_sshPort.Value) ? 22 : (int)_sshPort.Value,
                    Username = NullIfEmpty(_sshUser.Text.Trim()),
                    AuthMethod = (SshAuthMethod)Math.Max(0, _sshAuth.SelectedIndex),
                    PrivateKeyPath = string.IsNullOrWhiteSpace(_sshKey.Text) ? null : Environment.ExpandEnvironmentVariables(_sshKey.Text.Trim()),
                    JumpHosts = NullIfEmpty(_jump.Text.Trim()),
                }),
                Proxy = Keep(_existing?.Proxy, transport == ConnectionTransport.Proxy, !string.IsNullOrWhiteSpace(_proxyHost.Text), on => new ProxySettings
                {
                    Enabled = on,
                    Protocol = _proxyProtocol.SelectedIndex == 1 ? ProxyProtocol.HttpConnect : ProxyProtocol.Socks5,
                    Host = _proxyHost.Text.Trim(),
                    Port = double.IsNaN(_proxyPort.Value) ? 1080 : (int)_proxyPort.Value,
                    Username = NullIfEmpty(_proxyUser.Text.Trim()),
                }),
                CloudSqlProxy = Keep(_existing?.CloudSqlProxy, transport == ConnectionTransport.CloudSqlProxy, !string.IsNullOrWhiteSpace(_cloudSqlInstance.Text), on => new CloudSqlProxySettings
                {
                    Enabled = on,
                    InstanceConnectionName = _cloudSqlInstance.Text.Trim(),
                    AuthMode = _cloudSqlAuth.SelectedIndex == 1 ? CloudSqlAuthMode.ServiceAccountKey : CloudSqlAuthMode.ApplicationDefault,
                    UseIamAuth = _cloudSqlIam.IsChecked == true,
                    UsePrivateIp = _cloudSqlPrivateIp.IsChecked == true,
                    LocalPort = PortOrNull(_cloudSqlPort),
                    ExecutablePath = NullIfEmpty(Environment.ExpandEnvironmentVariables(_cloudSqlPath.Text.Trim())),
                }),
                CloudflareTunnel = Keep(_existing?.CloudflareTunnel, transport == ConnectionTransport.CloudflareTunnel, !string.IsNullOrWhiteSpace(_cloudflareHost.Text), on => new CloudflareTunnelSettings
                {
                    Enabled = on,
                    AccessHostname = _cloudflareHost.Text.Trim(),
                    AuthMethod = _cloudflareAuth.SelectedIndex == 1 ? CloudflareAuthMethod.ServiceToken : CloudflareAuthMethod.BrowserSso,
                    LocalPort = PortOrNull(_cloudflarePort),
                    ExposeToLan = _cloudflareLan.IsChecked == true,
                    ExecutablePath = NullIfEmpty(Environment.ExpandEnvironmentVariables(_cloudflarePath.Text.Trim())),
                }),
                TunnelCommand = Keep(_existing?.TunnelCommand, transport == ConnectionTransport.TunnelCommand, HasTunnelCommandInput(), on => BuildTunnelCommand() with { Enabled = on }),
            };
            return profile;
        }

        private bool HasTunnelCommandInput() =>
            !string.IsNullOrWhiteSpace(_command.Text) || !string.IsNullOrWhiteSpace(_kubeResource.Text) || !string.IsNullOrWhiteSpace(_ssmTarget.Text);

        private TunnelCommandSettings BuildTunnelCommand() => new()
        {
            Method = (TunnelCommandMethod)Math.Max(0, _commandMethod.SelectedIndex),
            Command = NullIfEmpty(_command.Text.Trim()),
            ExecutablePath = NullIfEmpty(Environment.ExpandEnvironmentVariables(_commandPath.Text.Trim())),
            KubernetesResource = NullIfEmpty(_kubeResource.Text.Trim()),
            KubernetesNamespace = NullIfEmpty(_kubeNamespace.Text.Trim()),
            KubernetesContext = NullIfEmpty(_kubeContext.Text.Trim()),
            AwsTarget = NullIfEmpty(_ssmTarget.Text.Trim()),
            AwsProfile = NullIfEmpty(_ssmProfile.Text.Trim()),
            AwsRegion = NullIfEmpty(_ssmRegion.Text.Trim()),
        };

        private ConnectionAuthSettings? BuildAuth()
        {
            var method = SelectedSignIn;
            if (method == SignInMethod.Password && _existing?.Auth is null)
            {
                return null;
            }

            return new ConnectionAuthSettings
            {
                Method = method,
                AwsRegion = NullIfEmpty(_awsRegion.Text.Trim()),
                AwsAccessKeyId = NullIfEmpty(_awsAccessKey.Text.Trim()),
                AwsProfileName = NullIfEmpty(_awsProfile.Text.Trim()),
                AwsRdsEndpoint = NullIfEmpty(_awsEndpoint.Text.Trim()),
                EntraMode = SelectedEntraMode,
                EntraTenantId = NullIfEmpty(_entraTenant.Text.Trim()),
                EntraClientId = NullIfEmpty(_entraClient.Text.Trim()),
                KerberosServiceName = NullIfEmpty(_kerberosService.Text.Trim()),
                GssEncryption = (GssEncryptionMode)Math.Max(0, _gssEncryption.SelectedIndex),
            };
        }

        private static string? SignInProblem(ConnectionProfile profile)
        {
            var method = profile.EffectiveSignIn();
            var auth = profile.Auth;
            if (method.IsAwsIam() && string.IsNullOrWhiteSpace(profile.Username))
            {
                return "Enter the database user the IAM token signs in as.";
            }

            if (method == SignInMethod.AwsIamAccessKey && string.IsNullOrWhiteSpace(auth?.AwsAccessKeyId))
            {
                return "Enter the access key ID.";
            }

            if (method == SignInMethod.EntraId && auth?.EntraMode == EntraAuthMode.ServicePrincipal && string.IsNullOrWhiteSpace(auth.EntraClientId))
            {
                return "Enter the service principal's application (client) ID.";
            }

            if (method == SignInMethod.EntraId && auth?.EntraMode == EntraAuthMode.ServicePrincipal && profile.Engine != DatabaseEngine.SqlServer && string.IsNullOrWhiteSpace(auth.EntraTenantId))
            {
                return "Enter the directory (tenant) ID for the service principal.";
            }

            return null;
        }

        private FrameworkElement Build(out SelectorBar sections)
        {
            foreach (var engine in _engines)
            {
                _engine.Items.Add(engine.QueryLanguage is "SQL" ? engine.DisplayName : $"{engine.DisplayName}  ({engine.QueryLanguage})");
            }

            AddItems(_ssl, "Disabled", "Preferred", "Required (skip verify)", "Verify CA", "Verify identity");
            AddItems(_safeMode, "Silent", "Alert", "Alert (Full)", "Safe Mode", "Safe Mode (Full)", "Read-Only");
            AddItems(_ai, "Ask each time", "Allow", "Never");
            AddItems(_mcp, "Blocked", "Read only", "Read and write, each write approved");
            AddItems(_sshAuth, "SSH agent", "Private key", "Password");
            AddItems(_gssEncryption, "Disabled", "Preferred", "Required");
            AddItems(_proxyProtocol, "SOCKS5", "HTTP (CONNECT)");
            AddItems(_cloudSqlAuth, "Application Default Credentials", "Service Account Key");
            AddItems(_cloudflareAuth, "Browser sign-in", "Service token");
            AddItems(_commandMethod, "kubectl port-forward", "AWS SSM session", "Custom command");

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
            _auth.SelectionChanged += (_, _) => UpdateSignInFields();
            _entraMode.SelectionChanged += (_, _) => UpdateSignInFields();
            _transport.SelectionChanged += (_, _) => UpdateTransportFields();
            _sshAuth.SelectionChanged += (_, _) => _sshKey.Visibility = Visible(_sshAuth.SelectedIndex == 1);
            _proxyUser.TextChanged += (_, _) => _proxyPassword.Visibility = Visible(!string.IsNullOrWhiteSpace(_proxyUser.Text));
            _cloudSqlAuth.SelectionChanged += (_, _) => UpdateTransportFields();
            _cloudflareAuth.SelectionChanged += (_, _) => UpdateTransportFields();
            _commandMethod.SelectionChanged += (_, _) => UpdateTransportFields();
            _command.TextChanged += (_, _) => UpdateCommandPreview();
            _kubeResource.TextChanged += (_, _) => UpdateCommandPreview();
            _ssmTarget.TextChanged += (_, _) => UpdateCommandPreview();
            _host_.TextChanged += (_, _) => UpdateCommandPreview();
            _cloudflareSignIn.Click += async (_, _) => await SignInToCloudflareAsync();
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

            _network.Children.Add(Row(_host_, _port));
            _network.Children.Add(_auth);
            _network.Children.Add(_user);
            _network.Children.Add(_password);
            _network.Children.Add(_savePassword);
            AddChildren(_awsFields, _awsRegion, _awsAccessKey, _awsProfile, _awsEndpoint);
            AddChildren(_entraFields, _entraMode, _entraTenant, _entraClient);
            AddChildren(_kerberosFields, _kerberosService, _gssEncryption);
            _network.Children.Add(_awsFields);
            _network.Children.Add(_entraFields);
            _network.Children.Add(_kerberosFields);
            _network.Children.Add(_authNote);
            _network.Children.Add(_database);

            _fileRow.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
            _fileRow.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
            _fileRow.Children.Add(_file);
            Grid.SetColumn(_browse, 1);
            _fileRow.Children.Add(_browse);

            var general = Section(_name, _engine, _network, _fileRow, _group, Labeled("Color", _colors));

            var ssl = Section(_ssl, Note("Preferred encrypts when the server offers it. The Verify modes check the server's certificate against the Windows certificate store, and Verify identity also checks the host name. IAM and Entra sign-ins always encrypt."));

            AddChildren(_sshFields, Row(_sshHost, _sshPort), _sshUser, _sshAuth, _sshKey, _sshSecret, _jump,
                Note("TablePro runs the OpenSSH client that ships with Windows, so your ~/.ssh/config, known_hosts and agent apply."));
            AddChildren(_proxyFields, _proxyProtocol, Row(_proxyHost, _proxyPort), _proxyUser, _proxyPassword,
                Note("Leave the user blank to connect without authentication. The proxy resolves the database host name. The password is stored in Windows Credential Manager."));
            AddChildren(_cloudSqlFields, _cloudSqlInstance, Note("Find this on the instance's overview page in the Google Cloud console."),
                _cloudSqlAuth, _cloudSqlAdcNote, _cloudSqlKey, _cloudSqlIam, _cloudSqlPrivateIp, _cloudSqlPort, _cloudSqlPath,
                Note("With IAM database authentication on, set the user to the IAM principal; the password is not used. The proxy listens only on 127.0.0.1."));
            AddChildren(_cloudflareFields, _cloudflareHost, _cloudflareAuth, _cloudflareSignIn, _cloudflareTokenId, _cloudflareTokenSecret,
                _cloudflarePort, _cloudflareLan, _cloudflarePath,
                Note("A service token needs an Access policy with a Service Auth rule, or Cloudflare still asks for a browser sign-in."));
            AddChildren(_kubectlFields, _kubeResource, _kubeNamespace, _kubeContext);
            AddChildren(_ssmFields, _ssmTarget, _ssmProfile, _ssmRegion);
            AddChildren(_commandFields, _commandMethod, _kubectlFields, _ssmFields, _command, _commandPath,
                Note("{port} is the local port TablePro picks; {host} and {remotePort} are the database's. The command runs as a program with its arguments, never through a shell."),
                Labeled("Will run", _commandPreview));
            var networkPage = Section(_transport, _transportNote, _sshFields, _proxyFields, _cloudSqlFields, _cloudflareFields, _commandFields);

            var advanced = Section(_safeMode, _ai, _mcp, _timeout, _startup, _options);

            var pages = new Dictionary<string, FrameworkElement> { ["General"] = general, ["SSL"] = ssl, ["Network"] = networkPage, ["Advanced"] = advanced };
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
            _filling = true;
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

            var auth = p.Auth ?? new ConnectionAuthSettings();
            _awsRegion.Text = auth.AwsRegion ?? string.Empty;
            _awsAccessKey.Text = auth.AwsAccessKeyId ?? string.Empty;
            _awsProfile.Text = auth.AwsProfileName ?? string.Empty;
            _awsEndpoint.Text = auth.AwsRdsEndpoint ?? string.Empty;
            _entraTenant.Text = auth.EntraTenantId ?? string.Empty;
            _entraClient.Text = auth.EntraClientId ?? string.Empty;
            _kerberosService.Text = auth.KerberosServiceName ?? string.Empty;
            _gssEncryption.SelectedIndex = (int)auth.GssEncryption;

            var ssh = p.Ssh ?? new SshTunnelSettings();
            _sshHost.Text = ssh.Host;
            _sshPort.Value = ssh.Port;
            _sshUser.Text = ssh.Username ?? string.Empty;
            _sshAuth.SelectedIndex = (int)ssh.AuthMethod;
            _sshKey.Text = ssh.PrivateKeyPath ?? string.Empty;
            _sshKey.Visibility = Visible(ssh.AuthMethod == SshAuthMethod.PrivateKey);
            _jump.Text = ssh.JumpHosts ?? string.Empty;

            var proxy = p.Proxy ?? new ProxySettings();
            _proxyProtocol.SelectedIndex = proxy.Protocol == ProxyProtocol.HttpConnect ? 1 : 0;
            _proxyHost.Text = proxy.Host;
            _proxyPort.Value = proxy.Port;
            _proxyUser.Text = proxy.Username ?? string.Empty;
            _proxyPassword.Visibility = Visible(!string.IsNullOrWhiteSpace(proxy.Username));

            var cloudSql = p.CloudSqlProxy ?? new CloudSqlProxySettings();
            _cloudSqlInstance.Text = cloudSql.InstanceConnectionName;
            _cloudSqlAuth.SelectedIndex = cloudSql.AuthMode == CloudSqlAuthMode.ServiceAccountKey ? 1 : 0;
            _cloudSqlIam.IsChecked = cloudSql.UseIamAuth;
            _cloudSqlPrivateIp.IsChecked = cloudSql.UsePrivateIp;
            _cloudSqlPort.Value = cloudSql.LocalPort ?? double.NaN;
            _cloudSqlPath.Text = cloudSql.ExecutablePath ?? string.Empty;

            var cloudflare = p.CloudflareTunnel ?? new CloudflareTunnelSettings();
            _cloudflareHost.Text = cloudflare.AccessHostname;
            _cloudflareAuth.SelectedIndex = cloudflare.AuthMethod == CloudflareAuthMethod.ServiceToken ? 1 : 0;
            _cloudflarePort.Value = cloudflare.LocalPort ?? double.NaN;
            _cloudflareLan.IsChecked = cloudflare.ExposeToLan;
            _cloudflarePath.Text = cloudflare.ExecutablePath ?? string.Empty;

            var command = p.TunnelCommand ?? new TunnelCommandSettings();
            _commandMethod.SelectedIndex = (int)command.Method;
            _command.Text = command.Command ?? string.Empty;
            _commandPath.Text = command.ExecutablePath ?? string.Empty;
            _kubeResource.Text = command.KubernetesResource ?? string.Empty;
            _kubeNamespace.Text = command.KubernetesNamespace ?? string.Empty;
            _kubeContext.Text = command.KubernetesContext ?? string.Empty;
            _ssmTarget.Text = command.AwsTarget ?? string.Empty;
            _ssmProfile.Text = command.AwsProfile ?? string.Empty;
            _ssmRegion.Text = command.AwsRegion ?? string.Empty;

            if (profile is not null)
            {
                _proxyPassword.Password = _host.Connector.SavedTransportSecret(profile, TransportSecret.ProxyPassword) ?? string.Empty;
                _cloudSqlKey.Text = _host.Connector.SavedTransportSecret(profile, TransportSecret.CloudSqlServiceAccountKey) ?? string.Empty;
                _cloudflareTokenId.Password = _host.Connector.SavedTransportSecret(profile, TransportSecret.CloudflareTokenId) ?? string.Empty;
                _cloudflareTokenSecret.Password = _host.Connector.SavedTransportSecret(profile, TransportSecret.CloudflareTokenSecret) ?? string.Empty;
            }

            _filling = false;
            OnEngineChanged();
            _auth.SelectedIndex = Math.Max(0, IndexOf(_authChoices, p.EffectiveSignIn()));
            _entraMode.SelectedIndex = Math.Max(0, IndexOf(_entraChoices, auth.EntraMode));
            _transport.SelectedIndex = Math.Max(0, IndexOf(_transportChoices, p.ActiveTransport()));
            UpdateSignInFields();
            UpdateTransportFields();
        }

        private void OnEngineChanged()
        {
            if (_filling)
            {
                return;
            }

            var descriptor = SelectedDescriptor;
            var form = EngineForm.For(descriptor.Engine);
            _network.Visibility = Visible(!descriptor.IsFileBased);
            _fileRow.Visibility = Visible(descriptor.IsFileBased || form.FileLabel is not null);
            _file.Header = form.FileLabel ?? "File";
            _host_.Header = form.HostLabel;
            _host_.PlaceholderText = form.HostPlaceholder;
            _port.Visibility = Visible(form.ShowPort);
            _user.Header = form.UserLabel;
            _database.Header = form.DatabaseLabel;
            _options.PlaceholderText = form.OptionsHint ?? "one key=value per line";
            _kerberosService.Header = form.KerberosServiceHeader ?? "Kerberos service name";
            _kerberosService.PlaceholderText = form.KerberosServicePlaceholder ?? string.Empty;
            _gssEncryption.Visibility = Visible(form.ShowGssEncryption);

            // Keep the chosen sign-in and transport when the new engine offers them too.
            var signIn = _authChoices.Count > 0 ? SelectedSignIn : SignInMethod.Password;
            _authChoices = form.SignInMethods;
            _auth.Items.Clear();
            foreach (var method in _authChoices)
            {
                _auth.Items.Add(method.DisplayName(descriptor.Engine));
            }

            _auth.SelectedIndex = Math.Max(0, IndexOf(_authChoices, signIn));
            _auth.Visibility = Visible(_authChoices.Count > 1);

            var entra = SelectedEntraMode;
            _entraChoices = SignInMethods.EntraModes(descriptor.Engine);
            _entraMode.Items.Clear();
            foreach (var mode in _entraChoices)
            {
                _entraMode.Items.Add(mode.DisplayName());
            }

            _entraMode.SelectedIndex = Math.Max(0, IndexOf(_entraChoices, entra));

            var transport = _transportChoices.Count > 0 ? SelectedTransport : ConnectionTransport.Direct;
            _transportChoices = form.Transports;
            _transport.Items.Clear();
            foreach (var choice in _transportChoices)
            {
                _transport.Items.Add(choice.DisplayName());
            }

            _transport.SelectedIndex = Math.Max(0, IndexOf(_transportChoices, transport));

            if (_existing is null || _existing.Engine != descriptor.Engine)
            {
                _port.Value = descriptor.DefaultPort;
                if (string.IsNullOrWhiteSpace(_user.Text) || EngineDescriptor.Engines.Any(d => d.DefaultUser == _user.Text))
                {
                    _user.Text = descriptor.DefaultUser;
                }
            }

            UpdateSignInFields();
            UpdateTransportFields();
        }

        /// <summary>Shows the fields the chosen sign-in uses, and names the secret field for what it holds.</summary>
        private void UpdateSignInFields()
        {
            if (_filling || _authChoices.Count == 0)
            {
                return;
            }

            var engine = SelectedDescriptor.Engine;
            var form = EngineForm.For(engine);
            var method = SelectedSignIn;
            var entraMode = SelectedEntraMode;
            var probe = new ConnectionProfile
            {
                Name = string.Empty,
                Engine = engine,
                Auth = new ConnectionAuthSettings { Method = method, EntraMode = entraMode },
            };

            _user.Visibility = Visible(form.ShowUser && probe.UsesUsername());
            _user.Header = method switch
            {
                SignInMethod.EntraId when engine == DatabaseEngine.SqlServer => "Account (login hint, optional)",
                SignInMethod.EntraId => "Entra user or group",
                _ when method.IsAwsIam() => "Database user",
                _ => form.UserLabel,
            };
            var usesSecret = probe.UsesSecret();
            _password.Visibility = Visible(usesSecret);
            _savePassword.Visibility = Visible(usesSecret);
            _password.Header = method == SignInMethod.Password ? form.PasswordLabel : SignInMethods.SecretLabel(method, entraMode);

            _awsFields.Visibility = Visible(method.IsAwsIam());
            _awsAccessKey.Visibility = Visible(method == SignInMethod.AwsIamAccessKey);
            _awsProfile.Visibility = Visible(method is SignInMethod.AwsIamProfile or SignInMethod.AwsIamSso);
            _entraFields.Visibility = Visible(method == SignInMethod.EntraId);
            _entraTenant.Visibility = Visible(engine != DatabaseEngine.SqlServer && entraMode is not EntraAuthMode.ManagedIdentity);
            _entraClient.Visibility = Visible(entraMode is EntraAuthMode.ServicePrincipal or EntraAuthMode.ManagedIdentity or EntraAuthMode.Default
                || (engine != DatabaseEngine.SqlServer && entraMode is EntraAuthMode.Interactive or EntraAuthMode.DeviceCode));
            _entraClient.Header = entraMode is EntraAuthMode.ManagedIdentity or EntraAuthMode.Default
                ? "Managed identity client ID (optional)"
                : entraMode == EntraAuthMode.ServicePrincipal ? "Application (client) ID" : "Application (client) ID (optional)";
            _kerberosFields.Visibility = Visible(method == SignInMethod.Kerberos);

            var note = method switch
            {
                SignInMethod.Kerberos => "Signs in with your Windows logon's Kerberos ticket. The host must be the server's name, not an IP address, for the ticket to be found.",
                SignInMethod.WindowsIntegrated => "Signs in as your Windows account, by Kerberos when the domain offers it.",
                SignInMethod.AwsIamProfile => "Reads the profile from %USERPROFILE%\\.aws\\config and credentials, including assumed roles and credential_process.",
                SignInMethod.AwsIamSso => "Uses the IAM Identity Center session that \u201Caws sso login\u201D left in the cache.",
                SignInMethod.AwsIamAccessKey => "Signs a 15-minute RDS token with the key on every new connection. The secret is stored in Windows Credential Manager.",
                SignInMethod.EntraId when entraMode == EntraAuthMode.DeviceCode => "The code is copied to the clipboard and the sign-in page opens; paste the code there.",
                SignInMethod.EntraId => "Signs in with Microsoft Entra ID and refreshes the token as connections open.",
                _ => string.Empty,
            };
            _authNote.Text = note;
            _authNote.Visibility = Visible(note.Length > 0);
        }

        private void UpdateTransportFields()
        {
            if (_filling || _transportChoices.Count == 0)
            {
                return;
            }

            var transport = SelectedDescriptor.IsFileBased ? ConnectionTransport.Direct : SelectedTransport;
            _transportNote.Text = transport.Summary();
            _sshFields.Visibility = Visible(transport == ConnectionTransport.Ssh);
            _proxyFields.Visibility = Visible(transport == ConnectionTransport.Proxy);
            _cloudSqlFields.Visibility = Visible(transport == ConnectionTransport.CloudSqlProxy);
            _cloudflareFields.Visibility = Visible(transport == ConnectionTransport.CloudflareTunnel);
            _commandFields.Visibility = Visible(transport == ConnectionTransport.TunnelCommand);

            var serviceAccount = _cloudSqlAuth.SelectedIndex == 1;
            _cloudSqlKey.Visibility = Visible(serviceAccount);
            _cloudSqlAdcNote.Visibility = Visible(!serviceAccount);

            var token = _cloudflareAuth.SelectedIndex == 1;
            _cloudflareTokenId.Visibility = Visible(token);
            _cloudflareTokenSecret.Visibility = Visible(token);
            _cloudflareSignIn.Visibility = Visible(!token);

            var method = (TunnelCommandMethod)Math.Max(0, _commandMethod.SelectedIndex);
            _kubectlFields.Visibility = Visible(method == TunnelCommandMethod.Kubectl);
            _ssmFields.Visibility = Visible(method == TunnelCommandMethod.AwsSsm);
            _command.Visibility = Visible(method == TunnelCommandMethod.Custom);
            _commandPath.Visibility = Visible(method != TunnelCommandMethod.Custom);
            _commandPath.PlaceholderText = method == TunnelCommandMethod.AwsSsm ? "aws.exe on PATH when empty" : "kubectl.exe on PATH when empty";
            UpdateCommandPreview();
        }

        private void UpdateCommandPreview()
        {
            if (_filling)
            {
                return;
            }

            var settings = BuildTunnelCommand();
            var port = double.IsNaN(_port.Value) || _port.Value <= 0 ? SelectedDescriptor.DefaultPort : (int)_port.Value;
            var problem = TunnelCommandLine.Validate(settings);
            _commandPreview.Text = problem ?? TunnelCommandLine.Preview(settings, string.IsNullOrWhiteSpace(_host_.Text) ? "localhost" : _host_.Text.Trim(), port);
        }

        private async Task SignInToCloudflareAsync()
        {
            if (string.IsNullOrWhiteSpace(_cloudflareHost.Text))
            {
                ShowStatus("Enter the Access application's hostname first.", InfoBarSeverity.Error);
                return;
            }

            _cloudflareSignIn.IsEnabled = false;
            try
            {
                ShowStatus("Finish signing in in your browser…", InfoBarSeverity.Informational);
                using var timeout = new CancellationTokenSource(TimeSpan.FromMinutes(5));
                var settings = new CloudflareTunnelSettings
                {
                    AccessHostname = _cloudflareHost.Text.Trim(),
                    ExecutablePath = NullIfEmpty(Environment.ExpandEnvironmentVariables(_cloudflarePath.Text.Trim())),
                };
                var message = await ConnectionService.SignInToCloudflareAsync(settings, timeout.Token);
                ShowStatus(message, message.StartsWith("Signed in", StringComparison.Ordinal) ? InfoBarSeverity.Success : InfoBarSeverity.Error);
            }
            catch (Exception ex)
            {
                ShowStatus(ex.Message, InfoBarSeverity.Error);
            }
            finally
            {
                _cloudflareSignIn.IsEnabled = true;
            }
        }

        /// <summary>
        /// The settings for a transport: on when chosen, kept turned off when the profile had them or something was
        /// typed, and absent otherwise so a profile that never used the transport stays as small as before.
        /// </summary>
        private static T? Keep<T>(T? existing, bool chosen, bool typed, Func<bool, T> build)
            where T : class =>
            !chosen && existing is null && !typed ? null : build(chosen);

        private static int? PortOrNull(NumberBox box) =>
            double.IsNaN(box.Value) || box.Value <= 0 ? null : (int)box.Value;

        private static int IndexOf<T>(IReadOnlyList<T> list, T value)
        {
            for (var i = 0; i < list.Count; i++)
            {
                if (EqualityComparer<T>.Default.Equals(list[i], value))
                {
                    return i;
                }
            }

            return -1;
        }

        private static Visibility Visible(bool visible) => visible ? Visibility.Visible : Visibility.Collapsed;

        private static string? NullIfEmpty(string text) => string.IsNullOrWhiteSpace(text) ? null : text;

        private static void AddItems(ComboBox box, params string[] items)
        {
            foreach (var item in items)
            {
                box.Items.Add(item);
            }
        }

        private static void AddChildren(Panel panel, params UIElement[] children)
        {
            foreach (var child in children)
            {
                panel.Children.Add(child);
            }
        }

        private static Grid Row(FrameworkElement main, FrameworkElement side)
        {
            var row = new Grid { ColumnSpacing = 8 };
            row.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
            row.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
            row.Children.Add(main);
            Grid.SetColumn(side, 1);
            row.Children.Add(side);
            return row;
        }

        private static StackPanel Section(params UIElement[] children)
        {
            var panel = new StackPanel { Spacing = 12, Padding = new Thickness(0, 4, 0, 4) };
            AddChildren(panel, children);
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
