using System.ComponentModel;
using System.Diagnostics;
using System.Text;
using TablePro.Storage.Localization;

namespace TablePro.Storage.Library.Git;

/// <summary>What a finished git process returned.</summary>
public sealed record GitProcessResult(int ExitCode, byte[] StandardOutput, byte[] StandardError)
{
    public bool Succeeded => ExitCode == 0;

    public string ErrorMessage => Text(StandardError);

    /// <summary>Both streams, since some failures such as "nothing to commit" are printed on standard output.</summary>
    public string CombinedOutput => string.Join('\n', new[] { Text(StandardOutput), ErrorMessage }.Where(s => s.Length > 0));

    public string OutputText => Text(StandardOutput);

    private static string Text(byte[] bytes) => Encoding.UTF8.GetString(bytes).Trim();
}

/// <summary>Runs git commands as child processes with a timeout, a cap on output and cancellation that ends the process tree.</summary>
public interface IGitProcessRunner
{
    Task<GitProcessResult> RunAsync(GitCommand command, CancellationToken cancellationToken = default);
}

/// <summary>
/// Runs <c>git.exe</c> without a shell. Arguments go through <see cref="ProcessStartInfo.ArgumentList"/>, so a commit
/// message or a file name is passed as one argument whatever it contains.
/// </summary>
public sealed class GitProcessRunner(string executablePath) : IGitProcessRunner
{
    public static readonly TimeSpan DefaultTimeout = TimeSpan.FromSeconds(20);
    public const int DefaultOutputLimit = 128 * 1024 * 1024;
    private const int ErrorOutputLimit = 64 * 1024;

    // A hook's background job or an SSH ControlPersist master can hold git's pipes open after git exits.
    private static readonly TimeSpan PipeDrainGrace = TimeSpan.FromSeconds(1);

    public string ExecutablePath { get; } = executablePath;

    public TimeSpan Timeout { get; init; } = DefaultTimeout;

    public int OutputLimit { get; init; } = DefaultOutputLimit;

    public async Task<GitProcessResult> RunAsync(GitCommand command, CancellationToken cancellationToken = default)
    {
        ArgumentNullException.ThrowIfNull(command);
        cancellationToken.ThrowIfCancellationRequested();

        var start = new ProcessStartInfo(ExecutablePath)
        {
            WorkingDirectory = command.WorkingDirectory,
            UseShellExecute = false,
            CreateNoWindow = true,
            RedirectStandardInput = true,
            RedirectStandardOutput = true,
            RedirectStandardError = true,
        };
        foreach (var argument in command.ProcessArguments)
        {
            start.ArgumentList.Add(argument);
        }

        start.Environment.Clear();
        var parent = System.Environment.GetEnvironmentVariables().Cast<System.Collections.DictionaryEntry>()
            .Select(e => new KeyValuePair<string, string>((string)e.Key, e.Value as string ?? string.Empty));
        foreach (var (key, value) in GitCommand.Environment(parent))
        {
            start.Environment[key] = value;
        }

        using var process = new Process { StartInfo = start };
        try
        {
            process.Start();
        }
        catch (Win32Exception ex)
        {
            throw new GitProcessException(GitProcessFailure.LaunchFailed, ex.Message, ex);
        }
        catch (InvalidOperationException ex)
        {
            throw new GitProcessException(GitProcessFailure.LaunchFailed, ex.Message, ex);
        }

        // Git never reads standard input for these commands; closing it makes any prompt fail instead of hang.
        process.StandardInput.Close();

        using var timeout = new CancellationTokenSource(command.Timeout ?? Timeout);
        using var linked = CancellationTokenSource.CreateLinkedTokenSource(cancellationToken, timeout.Token);
        var overflowed = false;
        var output = DrainAsync(process.StandardOutput.BaseStream, OutputLimit, () =>
        {
            overflowed = true;
            Kill(process);
        });
        var errors = DrainAsync(process.StandardError.BaseStream, ErrorOutputLimit, onOverflow: null);

        try
        {
            await process.WaitForExitAsync(linked.Token);
        }
        catch (OperationCanceledException)
        {
            Kill(process);
            await WhenDrained(output, errors, TimeSpan.FromSeconds(2));
            if (timeout.IsCancellationRequested && !cancellationToken.IsCancellationRequested)
            {
                throw new GitProcessException(GitProcessFailure.TimedOut, StorageStrings.Get("Library/GitTimedOut"));
            }

            throw;
        }

        await WhenDrained(output, errors, PipeDrainGrace);
        if (overflowed)
        {
            throw new GitProcessException(GitProcessFailure.OutputTooLarge, StorageStrings.Get("Library/GitOutputTooLarge"));
        }

        return new GitProcessResult(process.ExitCode, Collected(output), Collected(errors));
    }

    private static async Task<MemoryStream> DrainAsync(Stream source, int limit, Action? onOverflow)
    {
        var buffer = new MemoryStream();
        var chunk = new byte[64 * 1024];
        try
        {
            while (true)
            {
                var read = await source.ReadAsync(chunk);
                if (read == 0)
                {
                    break;
                }

                if (buffer.Length + read > limit)
                {
                    onOverflow?.Invoke();
                    if (onOverflow is not null)
                    {
                        break;
                    }

                    // Standard error past its cap is dropped rather than failing the command.
                    continue;
                }

                buffer.Write(chunk, 0, read);
            }
        }
        catch (IOException)
        {
        }
        catch (ObjectDisposedException)
        {
        }

        return buffer;
    }

    private static async Task WhenDrained(Task output, Task errors, TimeSpan grace)
    {
        await Task.WhenAny(Task.WhenAll(output, errors), Task.Delay(grace));
    }

    private static byte[] Collected(Task<MemoryStream> drain) =>
        drain.IsCompletedSuccessfully ? drain.Result.ToArray() : [];

    private static void Kill(Process process)
    {
        try
        {
            // The whole tree, so a hook git is waiting on ends with it.
            process.Kill(entireProcessTree: true);
        }
        catch (InvalidOperationException)
        {
        }
        catch (Win32Exception)
        {
        }
    }
}
