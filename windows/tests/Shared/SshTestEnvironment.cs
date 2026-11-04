using System.Globalization;

namespace TablePro.Testing;

internal static class SshTestEnvironment
{
    public static bool Available => !string.IsNullOrEmpty(Environment.GetEnvironmentVariable("TABLEPRO_TEST_SSH_POSTGRES_PORT"));

    public static int DatabasePort => int.Parse(Required("TABLEPRO_TEST_SSH_POSTGRES_PORT"), CultureInfo.InvariantCulture);

    public static string DatabasePassword => Required("TABLEPRO_TEST_SSH_POSTGRES_PASSWORD");

    public static string SshUser => Required("TABLEPRO_TEST_SSHD_USER");

    public static string SshPassword => Required("TABLEPRO_TEST_SSHD_PASSWORD");

    public static string SshKey => Required("TABLEPRO_TEST_SSHD_KEY");

    public static string LockedSshKey => Required("TABLEPRO_TEST_SSHD_LOCKED_KEY");

    public static string SshPassphrase => Required("TABLEPRO_TEST_SSHD_PASSPHRASE");

    public static string RotateScript => Required("TABLEPRO_TEST_SSH_ROTATE_SCRIPT");

    private static string Required(string name) =>
        Environment.GetEnvironmentVariable(name) is { Length: > 0 } value
            ? value
            : throw new InvalidOperationException($"The SSH fixture did not set {name}.");
}
