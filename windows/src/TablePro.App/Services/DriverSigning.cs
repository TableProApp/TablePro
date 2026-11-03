using TablePro.Interop;

namespace TablePro.App.Services;

// Who may sign a driver library, which the core matches after WinVerifyTrust.
internal static class DriverSigning
{
    // TablePro's own certificate joins this list once its Windows code signing certificate exists.
    private static readonly DriverSigner[] TableProSigners = [];

    public static IReadOnlyList<DriverSigner> Signers { get; } = Build();

    private static DriverSigner[] Build()
    {
#if DEBUG
        // A Debug build also trusts the test certificate windows.yml signs the UI tests' driver with.
        if (Environment.GetEnvironmentVariable("TABLEPRO_DRIVER_SIGNER") is { Length: > 0 } subject
            && Environment.GetEnvironmentVariable("TABLEPRO_DRIVER_SIGNER_ISSUER") is { Length: > 0 } issuer)
        {
            return [.. TableProSigners, new DriverSigner(subject, issuer)];
        }
#endif
        return TableProSigners;
    }
}
