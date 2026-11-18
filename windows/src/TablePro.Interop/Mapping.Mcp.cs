using Native = TablePro.Interop.Native;

namespace TablePro.Interop;

internal static partial class Mapping
{
    public static Native.ExternalAccessTag Access(ExternalAccess access) => access switch
    {
        ExternalAccess.Blocked => Native.ExternalAccessTag.Blocked,
        ExternalAccess.ReadWrite => Native.ExternalAccessTag.ReadWrite,
        _ => Native.ExternalAccessTag.ReadOnly,
    };

    public static ExternalAccess Access(Native.ExternalAccessTag access) => access switch
    {
        Native.ExternalAccessTag.Blocked => ExternalAccess.Blocked,
        Native.ExternalAccessTag.ReadWrite => ExternalAccess.ReadWrite,
        _ => ExternalAccess.ReadOnly,
    };

    public static McpServerStatus McpStatus(Native.McpStatusTag status) => status switch
    {
        Native.McpStatusTag.Starting starting => new(McpServerState.Starting, starting.Port),
        Native.McpStatusTag.Running running => new(McpServerState.Running, running.Port),
        Native.McpStatusTag.Failed failed => new(McpServerState.Failed, failed.Port, Error(failed.Error)),
        _ => McpServerStatus.Off,
    };

    public static McpClientSighting Sighting(Native.SeenClientInfo client) => new(
        client.Name,
        client.Title,
        client.Version,
        DateTimeOffset.FromUnixTimeMilliseconds(client.SeenAtMs));
}
