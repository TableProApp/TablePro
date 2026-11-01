using TablePro.Core.Licensing;
using TablePro.Storage.Licensing;

namespace TablePro.Storage.Tests.Licensing;

/// <summary>A license server answering from delegates; any call nobody set up fails the way an unreachable server does.</summary>
internal sealed class FakeLicenseApi : ILicenseApiClient
{
    public Func<LicenseClientRequest, SignedLicensePayload> Activate { get; set; } = _ => throw Offline();

    public Func<LicenseInviteRequest, SignedLicensePayload> AcceptInvite { get; set; } = _ => throw Offline();

    public Func<LicenseClientRequest, SignedLicensePayload> Validate { get; set; } = _ => throw Offline();

    public Func<LicenseClientRequest, LicenseActivations> Activations { get; set; } = _ => throw Offline();

    public Func<LicenseClientRequest, LicenseTeam> Team { get; set; } = _ => throw Offline();

    public Action<LicenseDeactivationRequest> Deactivate { get; set; } = _ => { };

    public LicenseClientRequest? LastRequest { get; private set; }

    public LicenseInviteRequest? LastInvite { get; private set; }

    public LicenseDeactivationRequest? LastDeactivation { get; private set; }

    public Task<SignedLicensePayload> ActivateAsync(LicenseClientRequest request, CancellationToken cancellationToken = default) =>
        Answer(() => Activate(LastRequest = request));

    public Task<SignedLicensePayload> AcceptInviteAsync(LicenseInviteRequest request, CancellationToken cancellationToken = default) =>
        Answer(() => AcceptInvite(LastInvite = request));

    public Task<SignedLicensePayload> ValidateAsync(LicenseClientRequest request, CancellationToken cancellationToken = default) =>
        Answer(() => Validate(LastRequest = request));

    public Task<LicenseActivations> ListActivationsAsync(LicenseClientRequest request, CancellationToken cancellationToken = default) =>
        Answer(() => Activations(request));

    public Task<LicenseTeam> TeamAsync(LicenseClientRequest request, CancellationToken cancellationToken = default) =>
        Answer(() => Team(request));

    public Task DeactivateAsync(LicenseDeactivationRequest request, CancellationToken cancellationToken = default) =>
        Answer(() =>
        {
            Deactivate(LastDeactivation = request);
            return true;
        });

    private static async Task<T> Answer<T>(Func<T> answer)
    {
        // Every real call completes asynchronously; yielding keeps the tests honest about reentrancy.
        await Task.Yield();
        return answer();
    }

    private static LicenseException Offline() => new(LicenseErrorKind.Network, "offline");
}
