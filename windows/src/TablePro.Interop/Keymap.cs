namespace TablePro.Interop;

public enum KeymapPlatform
{
    MacOs,
    Linux,
    Windows,
}

// Action is the keymap file's name for the command, such as executeQuery; Key is a VS Code key name. Derived marks a
// row read as Cmd to Ctrl from keys the source app published for macOS only.
public sealed record KeymapBinding(
    string Action,
    string Key,
    bool Control,
    bool Shift,
    bool Alt,
    bool Command,
    bool Derived);

public sealed record KeymapPresetInfo(string Id, string Name);
