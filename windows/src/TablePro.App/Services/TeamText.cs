using TablePro.App.Model;
using TablePro.Interop;

namespace TablePro.App.Services;

// Team Library and the team keys in words, worded as the macOS app's team sheets word them.
internal static class TeamText
{
    public static string Team(string? name) => string.IsNullOrWhiteSpace(name) ? Strings.Get("KeysUnnamedTeam") : name;

    // "Changed by Ana, 23/11/2026", or when alone, or nothing until a pull names anyone.
    public static string Changed(string? by, DateTimeOffset? at) => (by, at) switch
    {
        ({ Length: > 0 } who, { } stamp) => Strings.Format("TeamChangedByAt", who, stamp.LocalDateTime),
        ({ Length: > 0 } who, null) => Strings.Format("TeamChangedBy", who),
        (_, { } stamp) => Strings.Format("TeamChangedAt", stamp.LocalDateTime),
        _ => string.Empty,
    };

    public static string Outcome(TeamPublishOutcome outcome)
    {
        ArgumentNullException.ThrowIfNull(outcome);
        return outcome switch
        {
            TeamPublishOutcome.Unchanged => Strings.Get("TeamPublishUnchanged"),
            TeamPublishOutcome.Published published => Strings.Plural("TeamPublished", published.Edits, published.Edits),
            TeamPublishOutcome.Conflicts conflicts => Strings.Plural("TeamPublishConflicts", conflicts.Count, conflicts.Count),
            TeamPublishOutcome.Queued queued => Strings.Sentences(
                queued.Code is { } code ? SyncText.Code(code) : null,
                Strings.Get("TeamPublishQueued")),
            TeamPublishOutcome.Failed failed => SyncText.Code(failed.Code),
            TeamPublishOutcome.NotWritable => Strings.Get("TeamNotWritable"),
            _ => Strings.Get("TeamSignedOut"),
        };
    }

    public static string Unsent(UnsentTeamEdit edit)
    {
        ArgumentNullException.ThrowIfNull(edit);
        var name = TeamLibraryModel.Name(edit);
        return edit.State switch
        {
            UnsentTeamEditState.Conflict => Strings.Format("TeamUnsentConflict", name),
            UnsentTeamEditState.Refused => Strings.Format(
                "TeamUnsentRefused",
                name,
                edit.Code is { } code ? SyncText.Code(code) : Strings.Get("TeamRefusedUnknown")),
            _ => name,
        };
    }

    public static string ConflictTitle(TeamConflict conflict)
    {
        var name = TeamConflicts.Name(conflict) ?? conflict.Record.RecordId;
        return Strings.Format("TeamConflictTitle_" + TeamConflicts.Case(conflict), name);
    }

    public static string ConflictMessage(TeamConflict conflict, string? team) =>
        Strings.Format("TeamConflictMessage_" + TeamConflicts.Case(conflict), Team(team));

    // A field's label where this app names it; the key as the record holds it otherwise.
    public static string Field(string field) => Strings.Get("TeamField_" + field) is { Length: > 0 } label
        ? label
        : field;

    public static string Value(string? value) => value switch
    {
        null => Strings.Get("TeamValueNone"),
        "true" => Strings.Get("TeamValueYes"),
        "false" => Strings.Get("TeamValueNo"),
        _ => value,
    };

    public static string KeyStatus(TeamKeyStatus status) => Strings.Get("TeamKeyStatus_" + status);

    public static string MemberStatus(MemberKeyStatus status) => Strings.Get("TeamMemberStatus_" + status);

    public static string Role(TeamRole role) => Strings.Get("TeamRole_" + role);

    public static string MemberName(MemberKeys member)
    {
        ArgumentNullException.ThrowIfNull(member);
        var name = member.Name ?? member.Email ?? Strings.Get("KeysUnnamedTeammate");
        return member.IsSelf ? Strings.Format("TeamMemberYou", name) : name;
    }

    public static string Notice(TeamKeyNotice notice, MemberKeys? member)
    {
        ArgumentNullException.ThrowIfNull(notice);
        var name = member is null ? null : MemberName(member);
        return notice.Kind switch
        {
            TeamKeyNoticeKind.KeysChanged => Strings.Format("TeamNotice_KeysChanged", name ?? string.Empty),
            TeamKeyNoticeKind.RecoveryKeyReplaced => Strings.Format("TeamNotice_RecoveryKeyReplaced", name ?? string.Empty),
            TeamKeyNoticeKind.RestartHeld when name is not null => Strings.Format("TeamNotice_RestartHeld", name),
            TeamKeyNoticeKind.RestartHeld => Strings.Get("TeamNotice_RestartHeldStranger"),
            _ => Strings.Get("TeamNotice_" + notice.Kind),
        };
    }
}
