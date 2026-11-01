using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using System.Text.Json.Nodes;
using TablePro.Core.Connections;
using TablePro.Storage.Connections;

namespace TablePro.Storage.Library.Team;

/// <summary>A connection the team published, as the welcome window lists and opens it.</summary>
public sealed record TeamConnection(TeamLibraryConnection Source, ConnectionProfile Profile);

/// <summary>
/// Turns the team library's connection payloads (the macOS export format) into profiles the app can open, and a saved
/// profile into the payload a publish sends. A team connection is never saved: it opens as a connection of its own each
/// time, with the password asked for, so no secret of it is kept anywhere.
/// </summary>
public static class TeamLibraryConnections
{
    /// <summary>The macOS app's namespace for team library ids, the nil UUID.</summary>
    private static readonly Guid Namespace = Guid.Empty;

    /// <summary>
    /// The connections in <paramref name="library"/> this build can open, in the library's order. One the Windows app
    /// has no driver for, or whose payload does not read, is left out; ids that repeat are listed once.
    /// </summary>
    public static IReadOnlyList<TeamConnection> From(TeamLibraryPullResponse library)
    {
        ArgumentNullException.ThrowIfNull(library);
        var result = new List<TeamConnection>(library.Connections.Count);
        var seen = new HashSet<Guid>();
        foreach (var connection in library.Connections)
        {
            if (ToProfile(connection) is { } profile && seen.Add(profile.Id))
            {
                result.Add(new TeamConnection(connection, profile));
            }
        }

        return result;
    }

    /// <summary>The profile a team connection opens with, or null when this build cannot open it.</summary>
    public static ConnectionProfile? ToProfile(TeamLibraryConnection connection)
    {
        ArgumentNullException.ThrowIfNull(connection);
        PortableConnection? portable;
        try
        {
            portable = connection.Payload.Deserialize(StorageJsonContext.Default.PortableConnection);
        }
        catch (Exception ex) when (ex is JsonException or NotSupportedException or InvalidOperationException)
        {
            return null;
        }

        if (portable is null)
        {
            return null;
        }

        // The library has no groups or credential profiles of its own; a name in the payload must not create a group here.
        portable.GroupName = null;
        portable.GroupRef = null;
        portable.Ref = null;
        portable.CredentialProfileName = null;
        portable.CredentialProfileRef = null;

        // The import path applies the macOS import rules: blocked pre-connect fields dropped, tunnel commands off.
        var imported = ConnectionPortability.Import(new PortableConnectionFile { FormatVersion = 1, Connections = [portable] }, []);
        if (imported.Imported.Count == 0)
        {
            return null;
        }

        return imported.Imported[0] with
        {
            Id = StableId(Namespace, connection.Id),
            Group = null,
            LastConnectedAt = null,

            // Nothing of a team connection is saved, so a password sign-in asks each time, as macOS's promptForPassword.
            SavePassword = false,
        };
    }

    /// <summary>The payload a publish sends for <paramref name="profile"/>: the macOS export format, without passwords or groups.</summary>
    public static JsonObject Payload(ConnectionProfile profile)
    {
        ArgumentNullException.ThrowIfNull(profile);
        var file = ConnectionPortability.Export([profile], [], string.Empty, DateTimeOffset.UtcNow);
        return JsonSerializer.SerializeToNode(file.Connections[0], StorageJsonContext.Default.PortableConnection)!.AsObject();
    }

    /// <summary>
    /// The macOS <c>LinkedFolderWatcher.stableId</c>: SHA-256 of "namespace|key", its first 16 bytes stamped as a
    /// version 5 UUID. The same team connection gets the same id on every pull and in both apps, so its window, tabs and
    /// history stay with it.
    /// </summary>
    public static Guid StableId(Guid ns, string key)
    {
        ArgumentNullException.ThrowIfNull(key);
        Span<byte> digest = stackalloc byte[SHA256.HashSizeInBytes];
        SHA256.HashData(Encoding.UTF8.GetBytes(ns.ToString("D").ToUpperInvariant() + "|" + key), digest);
        var bytes = digest[..16];
        bytes[6] = (byte)((bytes[6] & 0x0F) | 0x50);
        bytes[8] = (byte)((bytes[8] & 0x3F) | 0x80);
        return new Guid(bytes, bigEndian: true);
    }
}
