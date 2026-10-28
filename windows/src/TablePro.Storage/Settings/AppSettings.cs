namespace TablePro.Storage.Settings;

public enum AppTheme
{
    System,
    Light,
    Dark,
}

public enum WindowBackdrop
{
    Mica,
    Acrylic,
    None,
    MicaAlt,
}

public enum AiProvider
{
    Anthropic,
    OpenAI,
    Ollama,
    OpenAICompatible,
    Gemini,
}

/// <summary>
/// Every preference the app keeps. Each value has a default, so a settings file written by an older build, or one
/// with fields removed by hand, still loads.
/// </summary>
public sealed record AppSettings
{
    public static AppSettings Default { get; } = new();

    public AppTheme Theme { get; init; } = AppTheme.System;
    public WindowBackdrop Backdrop { get; init; } = WindowBackdrop.Acrylic;
    public EditorSettings Editor { get; init; } = new();
    public DataSettings Data { get; init; } = new();
    public bool ConfirmCloseDirtyTabs { get; init; } = true;
    public bool RestoreSessionOnLaunch { get; init; } = true;
    public AiSettings Ai { get; init; } = new();
    public McpSettings Mcp { get; init; } = new();

    /// <summary>Pulls every number back into the range the UI accepts, so a hand-edited file cannot break the editor.</summary>
    public AppSettings Normalize() => this with
    {
        Editor = (Editor ?? new()).Normalize(),
        Data = (Data ?? new()).Normalize(),
        Ai = Ai ?? new(),
        Mcp = (Mcp ?? new()).Normalize(),
    };
}

public sealed record EditorSettings
{
    public const double MinFontSize = 6;
    public const double MaxFontSize = 72;

    public string FontFamily { get; init; } = "Cascadia Mono";
    public double FontSize { get; init; } = 13;
    public int TabSize { get; init; } = 4;
    public bool WordWrap { get; init; }
    public bool VimMode { get; init; }
    public bool Autocomplete { get; init; } = true;

    public EditorSettings Normalize() => this with
    {
        FontFamily = string.IsNullOrWhiteSpace(FontFamily) ? "Cascadia Mono" : FontFamily,
        FontSize = double.IsFinite(FontSize) ? Math.Clamp(FontSize, MinFontSize, MaxFontSize) : 13,
        TabSize = Math.Clamp(TabSize, 1, 16),
    };
}

/// <summary>How results and table data are fetched and shown.</summary>
public sealed record DataSettings
{
    /// <summary>The most rows an editor query reads before it stops and reports the result as truncated.</summary>
    public int EditorRowLimit { get; init; } = 10_000;

    /// <summary>Rows per page when browsing a table.</summary>
    public int TablePageSize { get; init; } = 500;

    /// <summary>A .NET format string for date and time cells.</summary>
    public string DateFormat { get; init; } = "yyyy-MM-dd HH:mm:ss";

    public string NullDisplayText { get; init; } = "NULL";

    public DataSettings Normalize() => this with
    {
        EditorRowLimit = Math.Clamp(EditorRowLimit, 1, 10_000_000),
        TablePageSize = Math.Clamp(TablePageSize, 10, 100_000),
        DateFormat = string.IsNullOrWhiteSpace(DateFormat) ? "yyyy-MM-dd HH:mm:ss" : DateFormat,
        NullDisplayText = NullDisplayText ?? "NULL",
    };
}

/// <summary>The AI assistant's provider. The API key is kept by the secret store under <c>SecretKeys.Ai</c>.</summary>
public sealed record AiSettings
{
    public AiProvider Provider { get; init; } = AiProvider.Anthropic;

    /// <summary>Null uses the provider's public endpoint. Required for Ollama and OpenAI-compatible servers on other hosts.</summary>
    public string? Endpoint { get; init; }

    public string? Model { get; init; }
    public bool InlineSuggestions { get; init; }
}

/// <summary>The local MCP server that lets AI clients query connections the user allowed.</summary>
public sealed record McpSettings
{
    public const int DefaultPort = 23_508;

    public bool Enabled { get; init; }
    public int Port { get; init; } = DefaultPort;

    public McpSettings Normalize() => this with { Port = Port is >= 1024 and <= 65535 ? Port : DefaultPort };
}
