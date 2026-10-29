using System.ComponentModel;
using System.Diagnostics;
using System.Text;
using TablePro.Drivers.Beancount.Localization;

namespace TablePro.Drivers.Beancount;

/// <summary>One run of an external program. Arguments stay a list so nothing is ever parsed back out of a command line.</summary>
internal sealed record ProcessSpec(
    string Executable,
    IReadOnlyList<string> Arguments,
    IReadOnlyDictionary<string, string>? Environment = null,
    string? StandardInput = null);

internal sealed record ProcessOutput(byte[] StandardOutput, string StandardError, int ExitCode)
{
    public string StandardOutputText => Encoding.UTF8.GetString(StandardOutput);
}

/// <summary>Runs a backend. Tests replace it with canned output.</summary>
internal interface IProcessRunner
{
    /// <summary>Runs to exit. Cancelling ends the whole process tree and throws <see cref="OperationCanceledException"/>.</summary>
    Task<ProcessOutput> RunAsync(ProcessSpec spec, CancellationToken cancellationToken);
}

internal sealed class SystemProcessRunner : IProcessRunner
{
    public static readonly SystemProcessRunner Instance = new();

    private static readonly UTF8Encoding Utf8NoBom = new(encoderShouldEmitUTF8Identifier: false);

    public async Task<ProcessOutput> RunAsync(ProcessSpec spec, CancellationToken cancellationToken)
    {
        cancellationToken.ThrowIfCancellationRequested();
        var startInfo = new ProcessStartInfo(spec.Executable)
        {
            UseShellExecute = false,
            CreateNoWindow = true,
            RedirectStandardOutput = true,
            RedirectStandardError = true,
            RedirectStandardInput = spec.StandardInput is not null,
            StandardErrorEncoding = Utf8NoBom,
        };
        if (spec.StandardInput is not null)
        {
            startInfo.StandardInputEncoding = Utf8NoBom;
        }

        foreach (var argument in spec.Arguments)
        {
            startInfo.ArgumentList.Add(argument);
        }

        if (spec.Environment is not null)
        {
            foreach (var (key, value) in spec.Environment)
            {
                startInfo.Environment[key] = value;
            }
        }

        using var process = new Process { StartInfo = startInfo };
        try
        {
            process.Start();
        }
        catch (Win32Exception ex)
        {
            throw new BeancountException(BeancountStrings.Format("Beancount/CouldNotStart", spec.Executable, ex.Message), ex);
        }

        // Read both pipes while the process runs: a backend that fills one pipe while we wait on the other never exits.
        var output = ReadAllAsync(process.StandardOutput.BaseStream);
        var error = process.StandardError.ReadToEndAsync(CancellationToken.None);
        try
        {
            if (spec.StandardInput is not null)
            {
                await WriteInputAsync(process.StandardInput, spec.StandardInput, cancellationToken);
            }

            await process.WaitForExitAsync(cancellationToken);
        }
        catch (OperationCanceledException)
        {
            KillTree(process);
            await DrainAsync(output, error);
            throw;
        }

        return new ProcessOutput(await output, await error, process.ExitCode);
    }

    private static async Task WriteInputAsync(StreamWriter input, string text, CancellationToken cancellationToken)
    {
        try
        {
            await input.WriteAsync(text.AsMemory(), cancellationToken);
            await input.FlushAsync(cancellationToken);
            input.Close();
        }
        catch (IOException)
        {
            // The process exited before reading all of its input; its exit code and stderr say why.
        }
    }

    private static async Task<byte[]> ReadAllAsync(Stream stream)
    {
        using var buffer = new MemoryStream();
        await stream.CopyToAsync(buffer, CancellationToken.None);
        return buffer.ToArray();
    }

    private static async Task DrainAsync(Task<byte[]> output, Task<string> error)
    {
        try
        {
            await Task.WhenAll(output, error);
        }
        catch (Exception ex) when (ex is IOException or ObjectDisposedException or InvalidOperationException)
        {
            // The pipes break when the tree is killed; what was read no longer matters.
        }
    }

    // py.exe starts python.exe as a child, so killing only the launcher would leave the interpreter running.
    private static void KillTree(Process process)
    {
        try
        {
            process.Kill(entireProcessTree: true);
        }
        catch (Exception ex) when (ex is InvalidOperationException or Win32Exception or NotSupportedException)
        {
            // It exited on its own between the cancellation and the kill.
        }
    }
}
