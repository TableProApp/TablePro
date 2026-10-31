using System.Text.Json.Serialization;

namespace TablePro.Storage.Licensing;

/// <summary>
/// What activation, validation, the device list and the team roster send: a credential plus this machine's identity,
/// under the macOS app's snake_case keys.
/// </summary>
public sealed record LicenseClientRequest(
    [property: JsonPropertyName("license_key")] string LicenseKey,
    [property: JsonPropertyName("machine_id")] string MachineId,
    [property: JsonPropertyName("machine_name")] string MachineName,
    [property: JsonPropertyName("app_version")] string AppVersion,
    [property: JsonPropertyName("os_version")] string OsVersion);

/// <summary>Accepting a team invitation, which activates this machine as a member.</summary>
public sealed record LicenseInviteRequest(
    [property: JsonPropertyName("token")] string Token,
    [property: JsonPropertyName("machine_id")] string MachineId,
    [property: JsonPropertyName("machine_name")] string MachineName,
    [property: JsonPropertyName("app_version")] string AppVersion,
    [property: JsonPropertyName("os_version")] string OsVersion);

/// <summary>Giving up a seat, this machine's or another one's on the same license.</summary>
public sealed record LicenseDeactivationRequest(
    [property: JsonPropertyName("license_key")] string LicenseKey,
    [property: JsonPropertyName("machine_id")] string MachineId);

/// <summary>The body of a deactivation and of every error. A body without <c>message</c> is not one this API wrote.</summary>
public sealed record LicenseMessageResponse
{
    [JsonPropertyName("message")]
    public required string Message { get; init; }
}

/// <summary>One machine a license is activated on.</summary>
public sealed record LicenseActivation(
    [property: JsonPropertyName("machine_id")] string MachineId,
    [property: JsonPropertyName("machine_name")] string MachineName,
    [property: JsonPropertyName("app_version")] string AppVersion,
    [property: JsonPropertyName("os_version")] string OsVersion,
    [property: JsonPropertyName("last_validated_at")] string? LastValidatedAt,
    [property: JsonPropertyName("created_at")] string CreatedAt);

public sealed record LicenseActivations(
    [property: JsonPropertyName("activations")] IReadOnlyList<LicenseActivation> Activations,
    [property: JsonPropertyName("max_activations")] int MaxActivations);

public sealed record LicenseTeamMember(
    [property: JsonPropertyName("email")] string Email,
    [property: JsonPropertyName("role")] string Role,
    [property: JsonPropertyName("joined_at")] string? JoinedAt);

/// <summary>A Team license's roster. Any other license answers with no members and no seats rather than an error.</summary>
public sealed record LicenseTeam(
    [property: JsonPropertyName("members")] IReadOnlyList<LicenseTeamMember> Members,
    [property: JsonPropertyName("seats_used")] int SeatsUsed,
    [property: JsonPropertyName("max_seats")] int MaxSeats);
