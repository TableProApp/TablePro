using TablePro.Storage.Localization;

namespace TablePro.Storage.Library.Git;

public enum GitProcessFailure
{
    LaunchFailed,
    TimedOut,
    OutputTooLarge,
}

/// <summary>Git could not be run to completion: it did not start, took too long, or printed too much.</summary>
public sealed class GitProcessException : Exception
{
    public GitProcessException()
        : this(GitProcessFailure.LaunchFailed, StorageStrings.Get("Library/GitCouldNotStart"))
    {
    }

    public GitProcessException(string message)
        : this(GitProcessFailure.LaunchFailed, message)
    {
    }

    public GitProcessException(string message, Exception innerException)
        : this(GitProcessFailure.LaunchFailed, message, innerException)
    {
    }

    public GitProcessException(GitProcessFailure failure, string message, Exception? innerException = null)
        : base(message, innerException)
    {
        Failure = failure;
    }

    public GitProcessFailure Failure { get; }
}

/// <summary>Git ran and exited with a failure status; <see cref="Exception.Message"/> is what it printed.</summary>
public class GitCommandException : Exception
{
    public GitCommandException()
        : this(1, string.Empty)
    {
    }

    public GitCommandException(string message)
        : this(1, message)
    {
    }

    public GitCommandException(string message, Exception innerException)
        : base(message, innerException)
    {
        ExitCode = 1;
        Output = message;
    }

    public GitCommandException(int exitCode, string output)
        : base(output.Length == 0 ? StorageStrings.Format("Library/GitExitStatus", exitCode) : output)
    {
        ExitCode = exitCode;
        Output = output;
    }

    public int ExitCode { get; }

    /// <summary>What git printed, empty when it printed nothing.</summary>
    public string Output { get; }
}

/// <summary>A pull stopped because the branch and its upstream each have commits the other lacks.</summary>
public sealed class GitPullDivergedException : GitCommandException
{
    public GitPullDivergedException()
    {
    }

    public GitPullDivergedException(string message)
        : base(message)
    {
    }

    public GitPullDivergedException(string message, Exception innerException)
        : base(message, innerException)
    {
    }

    public GitPullDivergedException(int exitCode, string output)
        : base(exitCode, output)
    {
    }
}

/// <summary>What a failed Git action has to show besides its summary, which the app words per exception type.</summary>
public static class GitErrorText
{
    /// <summary>What git printed, to show under the summary, or null.</summary>
    public static string? Output(Exception error) =>
        error is GitCommandException { Output.Length: > 0 } failure ? failure.Output : null;
}

/// <summary>No git executable was found.</summary>
public sealed class GitUnavailableException : Exception
{
    public GitUnavailableException()
        : base(StorageStrings.Get("Library/GitNotInstalled"))
    {
    }

    public GitUnavailableException(string message)
        : base(message)
    {
    }

    public GitUnavailableException(string message, Exception innerException)
        : base(message, innerException)
    {
    }
}
