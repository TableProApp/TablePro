using TablePro.Interop;

namespace TablePro.App.Model;

public enum TlsRemedy
{
    ChooseCaCertificate,
    SetServerName,
    ChangeEncryption,
}

public static class TlsRemedies
{
    // An expired or revoked certificate is the server's to replace, so it has no remedy here, nor has a name
    // mismatch where the engine checks only the host it dials.
    public static TlsRemedy? For(TlsFailure failure, bool serverNameShown) => failure switch
    {
        TlsFailure.UnknownIssuer => TlsRemedy.ChooseCaCertificate,
        TlsFailure.NameMismatch when serverNameShown => TlsRemedy.SetServerName,
        TlsFailure.ServerRefusedTls
            or TlsFailure.ServerRequiresTls
            or TlsFailure.ServerRefusedStrict
            or TlsFailure.ServerRequiresStrict => TlsRemedy.ChangeEncryption,
        _ => null,
    };
}
