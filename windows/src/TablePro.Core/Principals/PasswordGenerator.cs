using System.Security.Cryptography;

namespace TablePro.Core.Principals;

/// <summary>
/// Passwords for the create and change-password forms. The alphabet leaves out characters that read alike (0 and O,
/// 1, l and I), so a generated password survives being read aloud or typed from a screen, and quote characters, so it
/// needs no escaping in any engine's literal.
/// </summary>
public static class PasswordGenerator
{
    public const int DefaultLength = 20;

    private const string Alphabet = "abcdefghkmnopqrstuvwxyzABCDEFGHJKLMNPQRSTUVWXYZ23456789";

    public static string Generate(int length = DefaultLength) => length <= 0 ? string.Empty : RandomNumberGenerator.GetString(Alphabet, length);
}
