using Native = TablePro.Interop.Native;

namespace TablePro.Interop;

internal static partial class Mapping
{
    public static Native.KeymapPlatformTag Platform(KeymapPlatform platform) => platform switch
    {
        KeymapPlatform.MacOs => Native.KeymapPlatformTag.MacOs,
        KeymapPlatform.Linux => Native.KeymapPlatformTag.Linux,
        _ => Native.KeymapPlatformTag.Windows,
    };

    public static KeymapBinding Binding(Native.KeymapBindingInfo binding) => new(
        binding.Action,
        binding.Key,
        binding.Ctrl,
        binding.Shift,
        binding.Alt,
        binding.Cmd,
        binding.Derived);

    public static KeymapPresetInfo Preset(Native.KeymapPresetInfo preset) => new(preset.Id, preset.Name);
}
