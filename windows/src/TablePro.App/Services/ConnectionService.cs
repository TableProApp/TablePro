using TablePro.Core.Connections;
using TablePro.Core.Drivers;
using TablePro.Ssh;
using TablePro.Storage.Connections;
using TablePro.Storage.Secrets;

namespace TablePro.App.Services;

/// <summary>
/// Turns a saved profile into an open session: reads the saved password, dials the SSH tunnel when the profile has
/// one, and asks the engine's driver to connect through it. Every connect in the app goes through here.
/// </summary>
public sealed class ConnectionService(DriverRegistry drivers, ISecretStore secrets, ISshTunnelFactory tunnels, ConnectionStore connections)
{
    public DriverRegistry Drivers { get; } = drivers;

    public string? SavedPassword(ConnectionProfile profile) =>
        profile.SavePassword ? secrets.Get(SecretKeys.Connection(profile.Id)) : null;

    public string? SavedSshSecret(ConnectionProfile profile) => secrets.Get(SecretKeys.Ssh(profile.Id));

    public void SavePassword(ConnectionProfile profile, string? password)
    {
        if (profile.SavePassword && !string.IsNullOrEmpty(password))
        {
            secrets.Set(SecretKeys.Connection(profile.Id), password);
        }
        else
        {
            secrets.Delete(SecretKeys.Connection(profile.Id));
        }
    }

    public void SaveSshSecret(ConnectionProfile profile, string? secret)
    {
        if (!string.IsNullOrEmpty(secret))
        {
            secrets.Set(SecretKeys.Ssh(profile.Id), secret);
        }
        else
        {
            secrets.Delete(SecretKeys.Ssh(profile.Id));
        }
    }

    public void ForgetSecrets(ConnectionProfile profile)
    {
        secrets.Delete(SecretKeys.Connection(profile.Id));
        secrets.Delete(SecretKeys.Ssh(profile.Id));
    }

    /// <summary>Whether connecting needs a password the user has not saved.</summary>
    public bool NeedsPasswordPrompt(ConnectionProfile profile) =>
        !profile.Descriptor.IsFileBased && !profile.SavePassword && profile.Engine != DatabaseEngine.Sqlite;

    public async Task<(ConnectionSession Session, ConnectionRequest Request)> ConnectAsync(ConnectionProfile profile, string? password, CancellationToken cancellationToken, bool remember = true)
    {
        password ??= SavedPassword(profile);
        var request = ConnectionRequest.Direct(profile, password);
        SshTunnel? tunnel = null;
        if (profile.Ssh is { Enabled: true })
        {
            tunnel = await tunnels.OpenAsync(request, SavedSshSecret(profile), cancellationToken);
            request = tunnel.Request;
        }

        try
        {
            var session = await Drivers.Resolve(profile.Engine).ConnectAsync(request, cancellationToken);
            if (remember && connections.Find(profile.Id) is not null)
            {
                await connections.MarkConnectedAsync(profile.Id, cancellationToken: CancellationToken.None);
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
            return $"Connected to {profile.Descriptor.DisplayName} {session.Database.ServerVersion}".TrimEnd();
        }
    }
}
