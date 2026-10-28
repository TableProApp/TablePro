namespace TablePro.Core.Connections;

/// <summary>Mirrors the macOS app's SSL modes so a profile means the same thing on both platforms.</summary>
public enum SslMode
{
    Disabled,
    Preferred,
    Required,
    VerifyCa,
    VerifyIdentity,
}
