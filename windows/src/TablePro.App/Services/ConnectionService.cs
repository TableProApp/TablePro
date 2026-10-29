using System.Diagnostics;
using System.Globalization;
using Microsoft.UI.Dispatching;
using TablePro.Core.Connections;
using TablePro.Core.Drivers;
using TablePro.Ssh;
using TablePro.Ssh.SignIn;
using TablePro.Storage.Connections;
using TablePro.Storage.Secrets;
using Windows.ApplicationModel.DataTransfer;

namespace TablePro.App.Services;

/// <summary>Which transport secret a form field edits.</summary>
public enum TransportSecret
{
    ProxyPassword,
    CloudSqlServiceAccountKey,
    CloudflareTokenId,
    CloudflareTokenSecret,
}

/// <summary>
/// Turns a saved profile into an open session: reads the saved password, opens the profile's transport (an SSH
/// tunnel, a proxy, the Cloud SQL Auth Proxy, a Cloudflare tunnel or a tunnel command), and asks the engine's driver
/// to connect through it. Every connect in the app goes through here.
/// </summary>
public sealed class ConnectionService
{
    // Credential Manager holds at most 2,560 bytes per entry, about 1,280 UTF-16 characters, and a service account
    // key is longer, so long secrets are kept in numbered parts.
    private const int SecretPartLength = 1000;
    private const string PartsMarker = "parts:";

    private readonly ISecretStore _secrets;
    private readonly ISshTunnelFactory _tunnels;
    private readonly ConnectionStore _connections;
    private readonly INetworkTunnelFactory _networkTunnels;

    public ConnectionService(DriverRegistry drivers, ISecretStore secrets, ISshTunnelFactory tunnels, ConnectionStore connections)
        : this(drivers, secrets, tunnels, connections, new NetworkTunnelFactory())
    {
    }

    public ConnectionService(DriverRegistry drivers, ISecretStore secrets, ISshTunnelFactory tunnels, ConnectionStore connections, INetworkTunnelFactory networkTunnels)
    {
        Drivers = drivers;
        _secrets = secrets;
        _tunnels = tunnels;
        _connections = connections;
        _networkTunnels = networkTunnels;

        // Drivers reference only Core, so the SDKs that mint IAM and Entra tokens are installed here, once.
        SignInTokens.Provider ??= new CloudSignInTokenProvider();
        if (DispatcherQueue.GetForCurrentThread() is { } dispatcher)
        {
            SignInTokens.DeviceCodeHandler ??= (prompt, _) => ShowDeviceCodeAsync(dispatcher, prompt);
        }
    }

    public DriverRegistry Drivers { get; }

    // Kept in parts like the transport secrets, since a Google service account key takes the password's place.
    public string? SavedPassword(ConnectionProfile profile) =>
        profile.SavePassword ? GetLong(SecretKeys.Connection(profile.Id)) : null;

    public string? SavedSshSecret(ConnectionProfile profile) => _secrets.Get(SecretKeys.Ssh(profile.Id));

    public void SavePassword(ConnectionProfile profile, string? password)
    {
        SetLong(SecretKeys.Connection(profile.Id), profile.SavePassword ? password : null);
    }

    public void SaveSshSecret(ConnectionProfile profile, string? secret)
    {
        if (!string.IsNullOrEmpty(secret))
        {
            _secrets.Set(SecretKeys.Ssh(profile.Id), secret);
        }
        else
        {
            _secrets.Delete(SecretKeys.Ssh(profile.Id));
        }
    }

    public string? SavedTransportSecret(ConnectionProfile profile, TransportSecret secret) => GetLong(TransportKey(profile.Id, secret));

    /// <summary>Stores or, for an empty value, deletes a transport secret.</summary>
    public void SaveTransportSecret(ConnectionProfile profile, TransportSecret secret, string? value) => SetLong(TransportKey(profile.Id, secret), value);

    public void ForgetSecrets(ConnectionProfile profile)
    {
        SetLong(SecretKeys.Connection(profile.Id), null);
        _secrets.Delete(SecretKeys.Ssh(profile.Id));
        foreach (var secret in Enum.GetValues<TransportSecret>())
        {
            SetLong(TransportKey(profile.Id, secret), null);
        }
    }

    /// <summary>Stores what an encrypted import brought, under the imported profiles' ids.</summary>
    public void SaveImportedSecrets(ConnectionImportResult result)
    {
        ArgumentNullException.ThrowIfNull(result);
        foreach (var profile in result.Imported)
        {
            if (result.Secrets.TryGetValue(profile.Id, out var secrets))
            {
                SavePassword(profile, secrets.Password);
                SaveSshSecret(profile, secrets.SshSecret);
            }
        }
    }

    /// <summary>The saved secrets of a profile, for an encrypted export.</summary>
    public ConnectionSecrets? ExportableSecrets(ConnectionProfile profile) => new()
    {
        Password = SavedPassword(profile),
        SshSecret = profile.Ssh is { Enabled: true } ? SavedSshSecret(profile) : null,
    };

    /// <summary>
    /// Whether connecting needs a password the user has not saved. Kerberos, Windows and most token sign-ins send none;
    /// an AWS access key or a service principal keeps its secret where the password goes.
    /// </summary>
    public bool NeedsPasswordPrompt(ConnectionProfile profile) =>
        !profile.Descriptor.IsFileBased && !profile.SavePassword && profile.Engine != DatabaseEngine.Sqlite && profile.UsesSecret();

    public async Task<(ConnectionSession Session, ConnectionRequest Request)> ConnectAsync(ConnectionProfile profile, string? password, CancellationToken cancellationToken, bool remember = true)
    {
        if (profile.Validate() is { } problem)
        {
            throw new InvalidOperationException(problem);
        }

        password ??= SavedPassword(profile);
        var request = ConnectionRequest.Direct(profile, password);
        IConnectionTunnel? tunnel = null;
        var transport = profile.ActiveTransport();
        if (transport == ConnectionTransport.Ssh)
        {
            tunnel = await _tunnels.OpenAsync(request, SavedSshSecret(profile), cancellationToken);
        }
        else if (NetworkTunnelFactory.Handles(transport))
        {
            tunnel = await _networkTunnels.OpenAsync(request, TransportSecrets(profile, transport), cancellationToken);
        }

        if (tunnel is not null)
        {
            request = tunnel.Request;
        }

        try
        {
            // Redshift's IAM sign-in names the database user, which the driver must know before it opens the pool.
            request = await SignInTokens.PrepareAsync(request, cancellationToken);
            var session = await Drivers.Resolve(profile.Engine).ConnectAsync(request, cancellationToken);
            if (remember && _connections.Find(profile.Id) is not null)
            {
                await _connections.MarkConnectedAsync(profile.Id, cancellationToken: CancellationToken.None);
            }

            return (new ConnectionSession(session, tunnel), request);
        }
        catch
        {
            if (tunnel is not null)
            {
                await tunnel.DisposeAsync();
            }

            throw;
        }
    }

    /// <summary>Connects and disconnects at once, for the editor's Test button.</summary>
    public async Task<string> TestAsync(ConnectionProfile profile, string? password, CancellationToken cancellationToken)
    {
        var (session, _) = await ConnectAsync(profile, password, cancellationToken, remember: false);
        await using (session)
        {
            await session.Database.PingAsync(cancellationToken);
            return Strings.Format("Connection/TestSucceeded", profile.Descriptor.DisplayName, session.Database.ServerVersion).TrimEnd();
        }
    }

    /// <summary>
    /// Runs <c>cloudflared access login</c> for the profile's Access application, which opens the browser and caches
    /// the token cloudflared then uses on connect. Returns whether it succeeded, with the message for the form.
    /// </summary>
    public static async Task<(bool SignedIn, string Message)> SignInToCloudflareAsync(CloudflareTunnelSettings settings, CancellationToken cancellationToken)
    {
        ArgumentNullException.ThrowIfNull(settings);
        var executable = ExecutableLocator.Find(string.IsNullOrWhiteSpace(settings.ExecutablePath) ? HelperArguments.CloudflaredName : settings.ExecutablePath, ExecutableLocator.CloudflaredDirectories())
            ?? throw new InvalidOperationException(Strings.Get("Connection/CloudflaredNotFound"));
        var startInfo = new ProcessStartInfo(executable)
        {
            UseShellExecute = false,
            CreateNoWindow = true,
            RedirectStandardOutput = true,
            RedirectStandardError = true,
        };
        foreach (var argument in HelperArguments.CloudflaredLogin(settings))
        {
            startInfo.ArgumentList.Add(argument);
        }

        using var process = Process.Start(startInfo) ?? throw new InvalidOperationException(Strings.Get("Connection/CloudflaredDidNotStart"));
        var output = process.StandardOutput.ReadToEndAsync(cancellationToken);
        var errors = process.StandardError.ReadToEndAsync(cancellationToken);
        await process.WaitForExitAsync(cancellationToken);
        var text = (await output + await errors).Trim();
        return process.ExitCode == 0
            ? (true, Strings.Get("Connection/CloudflareSignedIn"))
            : (false, Strings.Format("Connection/CloudflareLoginFailed", text));
    }

    private NetworkTunnelSecrets TransportSecrets(ConnectionProfile profile, ConnectionTransport transport) => transport switch
    {
        ConnectionTransport.Proxy when !string.IsNullOrEmpty(profile.Proxy?.Username) => new() { ProxyPassword = SavedTransportSecret(profile, TransportSecret.ProxyPassword) },
        ConnectionTransport.CloudSqlProxy => new() { CloudSqlServiceAccountKey = SavedTransportSecret(profile, TransportSecret.CloudSqlServiceAccountKey) },
        ConnectionTransport.CloudflareTunnel => new()
        {
            CloudflareTokenId = SavedTransportSecret(profile, TransportSecret.CloudflareTokenId),
            CloudflareTokenSecret = SavedTransportSecret(profile, TransportSecret.CloudflareTokenSecret),
        },
        _ => new(),
    };

    private static string TransportKey(Guid id, TransportSecret secret) => secret switch
    {
        TransportSecret.ProxyPassword => TransportSecretKeys.ProxyPassword(id),
        TransportSecret.CloudSqlServiceAccountKey => TransportSecretKeys.CloudSqlServiceAccountKey(id),
        TransportSecret.CloudflareTokenId => TransportSecretKeys.CloudflareTokenId(id),
        _ => TransportSecretKeys.CloudflareTokenSecret(id),
    };

    private string? GetLong(string key)
    {
        var head = _secrets.Get(key);
        if (head is null || !head.StartsWith(PartsMarker, StringComparison.Ordinal)
            || !int.TryParse(head.AsSpan(PartsMarker.Length), NumberStyles.None, CultureInfo.InvariantCulture, out var count))
        {
            return head;
        }

        var parts = new string?[count];
        for (var i = 0; i < count; i++)
        {
            parts[i] = _secrets.Get(PartKey(key, i));
            if (parts[i] is null)
            {
                return null;
            }
        }

        return string.Concat(parts);
    }

    private void SetLong(string key, string? value)
    {
        if (_secrets.Get(key) is { } previous && previous.StartsWith(PartsMarker, StringComparison.Ordinal)
            && int.TryParse(previous.AsSpan(PartsMarker.Length), NumberStyles.None, CultureInfo.InvariantCulture, out var oldCount))
        {
            for (var i = 0; i < oldCount; i++)
            {
                _secrets.Delete(PartKey(key, i));
            }
        }

        if (string.IsNullOrEmpty(value))
        {
            _secrets.Delete(key);
            return;
        }

        if (value.Length <= SecretPartLength && !value.StartsWith(PartsMarker, StringComparison.Ordinal))
        {
            _secrets.Set(key, value);
            return;
        }

        var count = (value.Length + SecretPartLength - 1) / SecretPartLength;
        for (var i = 0; i < count; i++)
        {
            _secrets.Set(PartKey(key, i), value.Substring(i * SecretPartLength, Math.Min(SecretPartLength, value.Length - (i * SecretPartLength))));
        }

        _secrets.Set(key, PartsMarker + count.ToString(CultureInfo.InvariantCulture));
    }

    private static string PartKey(string key, int index) => key + "/" + index.ToString(CultureInfo.InvariantCulture);

    /// <summary>
    /// The macOS app's device code flow: the code goes to the clipboard and the verification page opens, so the user
    /// pastes it and signs in. The page shows the code's prompt too, in case the clipboard was overwritten.
    /// </summary>
    private static Task ShowDeviceCodeAsync(DispatcherQueue dispatcher, DeviceCodePrompt prompt)
    {
        var shown = new TaskCompletionSource();
        if (!dispatcher.TryEnqueue(() =>
        {
            try
            {
                var package = new DataPackage();
                package.SetText(prompt.UserCode);
                Clipboard.SetContent(package);
                if (prompt.VerificationUri.Scheme != Uri.UriSchemeHttps)
                {
                    throw new InvalidOperationException(prompt.Message);
                }

                Process.Start(new ProcessStartInfo(prompt.VerificationUri.AbsoluteUri) { UseShellExecute = true })?.Dispose();
                shown.SetResult();
            }
            catch (Exception ex) when (ex is System.ComponentModel.Win32Exception or InvalidOperationException or System.Runtime.InteropServices.COMException)
            {
                shown.SetException(new InvalidOperationException(prompt.Message, ex));
            }
        }))
        {
            shown.SetException(new InvalidOperationException(prompt.Message));
        }

        return shown.Task;
    }
}
