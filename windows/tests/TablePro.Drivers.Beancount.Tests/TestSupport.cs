using System.Collections.Concurrent;
using System.Text;
using Microsoft.Data.Sqlite;
using TablePro.Core.Connections;
using TablePro.Core.Drivers;

namespace TablePro.Drivers.Beancount.Tests;

/// <summary>Answers each process run from a handler, recording what was asked.</summary>
internal sealed class FakeProcessRunner(Func<ProcessSpec, CancellationToken, Task<ProcessOutput>> handler) : IProcessRunner
{
    public ConcurrentQueue<ProcessSpec> Runs { get; } = new();

    public FakeProcessRunner(Func<ProcessSpec, ProcessOutput> handler)
        : this((spec, _) => Task.FromResult(handler(spec)))
    {
    }

    public Task<ProcessOutput> RunAsync(ProcessSpec spec, CancellationToken cancellationToken)
    {
        Runs.Enqueue(spec);
        return handler(spec, cancellationToken);
    }

    public static ProcessOutput Ok(string stdout) => new(Encoding.UTF8.GetBytes(stdout), string.Empty, 0);

    public static ProcessOutput Fail(string stderr, int exitCode = 1) => new([], stderr, exitCode);
}

/// <summary>A scratch directory removed when the test ends.</summary>
internal sealed class TempDirectory : IDisposable
{
    public TempDirectory()
    {
        Path = System.IO.Path.Combine(System.IO.Path.GetTempPath(), "tablepro-beancount-tests", Guid.NewGuid().ToString("N"));
        Directory.CreateDirectory(Path);
    }

    public string Path { get; }

    public string Write(string relativePath, string contents)
    {
        var full = System.IO.Path.GetFullPath(System.IO.Path.Combine(Path, relativePath));
        Directory.CreateDirectory(System.IO.Path.GetDirectoryName(full)!);
        File.WriteAllText(full, contents);
        return full;
    }

    /// <summary>Copies the sample ledger, so a test may change it.</summary>
    public string CopySamples()
    {
        foreach (var file in Directory.EnumerateFiles(Samples.Directory, "*", SearchOption.AllDirectories))
        {
            var target = System.IO.Path.Combine(Path, System.IO.Path.GetRelativePath(Samples.Directory, file));
            Directory.CreateDirectory(System.IO.Path.GetDirectoryName(target)!);
            File.Copy(file, target);
        }

        return System.IO.Path.Combine(Path, "main.beancount");
    }

    public void Dispose()
    {
        try
        {
            Directory.Delete(Path, recursive: true);
        }
        catch (IOException)
        {
        }
        catch (UnauthorizedAccessException)
        {
        }
    }
}

internal static class Samples
{
    public static string Directory => Path.Combine(AppContext.BaseDirectory, "Samples");

    public static string Ledger => Path.Combine(Directory, "main.beancount");

    public static string PythonOutput => File.ReadAllText(Path.Combine(Directory, "python-output.json"));

    public static ConnectionRequest Request(string ledgerPath, IReadOnlyDictionary<string, string>? options = null, int timeoutSeconds = 15) =>
        ConnectionRequest.Direct(
            new ConnectionProfile
            {
                Name = "ledger",
                Engine = DatabaseEngine.Beancount,
                FilePath = ledgerPath,
                ConnectTimeoutSeconds = timeoutSeconds,
                AdditionalOptions = options ?? new Dictionary<string, string>(),
            },
            null);

    /// <summary>A locator that finds <c>py.exe</c> in a fake PATH directory and nothing else.</summary>
    public static BeancountBackendLocator FakePythonLocator(IProcessRunner runner) =>
        new(runner, name => name == "PATH" ? @"C:\fake" : null, path => path == @"C:\fake\py.exe");

    /// <summary>A runner that answers the beancount probe and prints the canned projection.</summary>
    public static FakeProcessRunner PythonRunner(Func<string>? output = null) =>
        new(spec => spec.Arguments.Contains("-c") ? FakeProcessRunner.Ok("3.1.0\n") : FakeProcessRunner.Ok((output ?? (() => PythonOutput))()));
}

internal static class ProjectionQueries
{
    public static List<object?[]> Rows(BeancountProjection projection, string sql)
    {
        using var connection = new SqliteConnection(projection.ConnectionString);
        connection.Open();
        using var command = connection.CreateCommand();
        command.CommandText = sql;
        using var reader = command.ExecuteReader();
        var rows = new List<object?[]>();
        while (reader.Read())
        {
            var values = new object?[reader.FieldCount];
            for (var i = 0; i < values.Length; i++)
            {
                values[i] = reader.IsDBNull(i) ? null : reader.GetValue(i);
            }

            rows.Add(values);
        }

        return rows;
    }

    public static object? Scalar(BeancountProjection projection, string sql) => Rows(projection, sql)[0][0];
}
