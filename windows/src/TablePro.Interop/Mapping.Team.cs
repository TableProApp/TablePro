using Native = TablePro.Interop.Native;

namespace TablePro.Interop;

// Team Library's and the team keys' records; times cross as milliseconds from the Unix epoch.
internal static partial class Mapping
{
    public static TeamLibraryTeam Team(Native.TeamLibraryTeamInfo team) => new(
        team.TeamId,
        team.Name,
        team.Role is { } role ? Role(role) : null,
        team.CanWrite,
        [.. team.Items.Select(item => new TeamItem(
            Kind(item.Kind),
            item.Id,
            item.FieldsJson,
            item.UpdatedBy,
            item.UpdatedAtMs is { } at ? DateTimeOffset.FromUnixTimeMilliseconds(at) : null))]);

    public static TeamScopeStatus TeamStatus(Native.TeamScopeStatusInfo status) => new(
        status.TeamId,
        status.LastSyncedMs is { } at ? DateTimeOffset.FromUnixTimeMilliseconds(at) : null,
        status.PullOnly,
        status.WriteForbidden,
        status.Problem);

    public static TeamPublish Publish(Native.TeamPublishInfo publish) => new(
        checked((int)publish.Edits),
        checked((int)publish.Conflicts),
        checked((int)publish.Unsent),
        publish.Problem);

    public static Native.TeamLibraryItemRef ItemRef(TeamItemRef item) => new(
        item.Kind switch
        {
            TeamItemKind.Connection => Native.TeamLibraryKindTag.Connection,
            TeamItemKind.Folder => Native.TeamLibraryKindTag.Folder,
            _ => Native.TeamLibraryKindTag.Query,
        },
        item.Id);

    public static UnsentTeamEdit Unsent(Native.UnsentTeamEditInfo edit) => new(
        edit.TeamId,
        new TeamItemRef(Kind(edit.Item.Kind), edit.Item.Id),
        edit.Name,
        edit.Deletion,
        edit.State switch
        {
            Native.UnsentTeamEditTag.Conflict => UnsentTeamEditState.Conflict,
            Native.UnsentTeamEditTag.Refused => UnsentTeamEditState.Refused,
            Native.UnsentTeamEditTag.Waiting => UnsentTeamEditState.Waiting,
            _ => UnsentTeamEditState.Pending,
        },
        (edit.State as Native.UnsentTeamEditTag.Refused)?.Code);

    public static TeamConflict Conflict(Native.TeamConflictInfo conflict) => new(
        new SyncRecord(conflict.Record.Scope, conflict.Record.Kind, conflict.Record.RecordId),
        [.. conflict.Fields],
        conflict.Mine,
        conflict.Theirs,
        conflict.Digest);

    public static Native.SyncRecordRef Record(SyncRecord record) => new(record.Scope, record.Kind, record.RecordId);

    public static TeamKeys Keys(Native.TeamKeysInfo keys) => new(
        keys.Team,
        keys.TeamName,
        keys.Version,
        keys.State switch
        {
            Native.KeyVersionStateTag.Stopped => TeamKeyState.Stopped,
            Native.KeyVersionStateTag.Ended => TeamKeyState.Ended,
            _ => TeamKeyState.Ok,
        },
        keys.StoppedCause is { } cause ? Stop(cause) : null,
        keys.RotationDue,
        keys.Holder,
        [.. keys.Members.Select(member => new MemberKeys(
            member.Account,
            member.Name,
            member.Email,
            member.IsSelf,
            Role(member.Role),
            member.Status switch
            {
                Native.MemberKeyStatusTag.AwaitingConfirmation => MemberKeyStatus.AwaitingConfirmation,
                Native.MemberKeyStatusTag.Holder => MemberKeyStatus.Holder,
                Native.MemberKeyStatusTag.Alert => MemberKeyStatus.Alert,
                _ => MemberKeyStatus.NoKeys,
            }))],
        [.. keys.Stopped.Select(stopped => new StoppedDevice(
            stopped.Account,
            stopped.Name,
            stopped.Email,
            stopped.IsSelf,
            stopped.Device,
            stopped.Version,
            stopped.CanReconfirm))]);

    private static TeamItemKind Kind(Native.TeamLibraryKindTag kind) => kind switch
    {
        Native.TeamLibraryKindTag.Connection => TeamItemKind.Connection,
        Native.TeamLibraryKindTag.Folder => TeamItemKind.Folder,
        _ => TeamItemKind.Query,
    };

    private static TeamRole Role(Native.TeamRoleTag role) => role switch
    {
        Native.TeamRoleTag.Owner => TeamRole.Owner,
        Native.TeamRoleTag.Admin => TeamRole.Admin,
        Native.TeamRoleTag.Editor => TeamRole.Editor,
        _ => TeamRole.Member,
    };
}
