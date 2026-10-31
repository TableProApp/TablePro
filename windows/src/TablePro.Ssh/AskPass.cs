using System.Text;

namespace TablePro.Ssh;

/// <summary>
/// The SSH_ASKPASS answer. ssh runs the askpass program with the prompt as its only argument and reads the reply
/// from stdout. TablePro.exe is that program: the factory points SSH_ASKPASS at the app and sets
/// <see cref="ModeVariable"/>, and the app's entry point answers before any window starts. One self-contained
/// executable then serves both roles, with no second program that would need its own runtime.
/// </summary>
public static class AskPass
{
    public const string ModeVariable = "TABLEPRO_ASKPASS";

    public static bool IsRequested => Environment.GetEnvironmentVariable(ModeVariable) == "1";

    /// <summary>Answers on the process's real stdout, which ssh reads through a pipe.</summary>
    public static int Run(IReadOnlyList<string> args)
    {
        using var stdout = Console.OpenStandardOutput();
        using var writer = new StreamWriter(stdout, new UTF8Encoding(encoderShouldEmitUTF8Identifier: false));
        return Answer(args, Environment.GetEnvironmentVariable(SshTunnelFactory.SecretVariable), writer);
    }

    public static int Answer(IReadOnlyList<string> args, string? secret, TextWriter output)
    {
        var prompt = args.Count > 0 ? args[0] : string.Empty;

        // A host key question must never be answered with the password. With StrictHostKeyChecking=accept-new it
        // only comes up when a known key changed, and refusing is the safe answer.
        if (prompt.Contains("(yes/no", StringComparison.OrdinalIgnoreCase) || prompt.Contains("fingerprint", StringComparison.OrdinalIgnoreCase))
        {
            return 1;
        }

        if (string.IsNullOrEmpty(secret))
        {
            return 1;
        }

        output.Write(secret);
        output.Write('\n');
        output.Flush();
        return 0;
    }
}
