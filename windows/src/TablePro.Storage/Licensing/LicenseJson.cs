using System.Text.Json;
using System.Text.Json.Serialization;
using System.Text.Json.Serialization.Metadata;
using TablePro.Core.Licensing;

namespace TablePro.Storage.Licensing;

/// <summary>
/// The license API's wire format and the cache file. Keys come from each type's <see cref="JsonPropertyNameAttribute"/>,
/// so the cached payload keeps the server's snake_case and the envelope the macOS cache's two keys.
/// </summary>
[JsonSourceGenerationOptions(
    WriteIndented = true,
    AllowTrailingCommas = true,
    ReadCommentHandling = JsonCommentHandling.Skip)]
[JsonSerializable(typeof(License))]
[JsonSerializable(typeof(SignedLicensePayload))]
[JsonSerializable(typeof(LicenseClientRequest))]
[JsonSerializable(typeof(LicenseInviteRequest))]
[JsonSerializable(typeof(LicenseDeactivationRequest))]
[JsonSerializable(typeof(LicenseMessageResponse))]
[JsonSerializable(typeof(LicenseActivations))]
[JsonSerializable(typeof(LicenseTeam))]
internal sealed partial class LicenseJsonContext : JsonSerializerContext;

internal static class LicenseJson
{
    public static JsonTypeInfo<License> License => LicenseJsonContext.Default.License;

    public static JsonTypeInfo<SignedLicensePayload> Signed => LicenseJsonContext.Default.SignedLicensePayload;

    public static JsonTypeInfo<LicenseClientRequest> ClientRequest => LicenseJsonContext.Default.LicenseClientRequest;

    public static JsonTypeInfo<LicenseInviteRequest> InviteRequest => LicenseJsonContext.Default.LicenseInviteRequest;

    public static JsonTypeInfo<LicenseDeactivationRequest> DeactivationRequest => LicenseJsonContext.Default.LicenseDeactivationRequest;

    public static JsonTypeInfo<LicenseMessageResponse> Message => LicenseJsonContext.Default.LicenseMessageResponse;

    public static JsonTypeInfo<LicenseActivations> Activations => LicenseJsonContext.Default.LicenseActivations;

    public static JsonTypeInfo<LicenseTeam> Team => LicenseJsonContext.Default.LicenseTeam;
}
