using TablePro.Interop;

namespace TablePro.App.Model;

public enum LibraryEmptiness
{
    NotEmpty,

    // No connection and no group anywhere it shows: the first-run page.
    Library,

    // The active project holds nothing yet; other projects may.
    Project,
}

// One entry of a Move to project menu; a null Id is no project.
public sealed record ProjectChoice(Guid? Id, string? Name, bool IsCurrent);

// What the Connections page asks about the project a snapshot is narrowed to. The core does the narrowing.
public static class LibraryScope
{
    public static ConnectionProject? Active(LibrarySnapshot snapshot)
    {
        ArgumentNullException.ThrowIfNull(snapshot);
        return snapshot.Scope is { } id ? snapshot.Projects.FirstOrDefault(project => project.Id == id) : null;
    }

    // A setting can outlive its project, so an id no project holds reads as all connections.
    public static Guid? Resolve(Guid? active, IReadOnlyList<ConnectionProject> projects)
    {
        ArgumentNullException.ThrowIfNull(projects);
        return active is { } id && projects.Any(project => project.Id == id) ? id : null;
    }

    public static LibraryEmptiness Emptiness(LibrarySnapshot snapshot)
    {
        ArgumentNullException.ThrowIfNull(snapshot);
        if (snapshot.Connections.Count > 0 || snapshot.Groups.Count > 0)
        {
            return LibraryEmptiness.NotEmpty;
        }

        return Active(snapshot) is null ? LibraryEmptiness.Library : LibraryEmptiness.Project;
    }

    // A grouped connection follows its top-level group, so the core moves only ungrouped ones.
    public static bool CanMove(IReadOnlyList<SavedConnection> connections)
    {
        ArgumentNullException.ThrowIfNull(connections);
        return connections.Count > 0 && connections.All(connection => connection is { Id: not null, GroupId: null });
    }

    public static bool CanMove(ConnectionGroup group)
    {
        ArgumentNullException.ThrowIfNull(group);
        return group.ParentId is null;
    }

    // No project first, then each project in its order; the one every moved item is in already is current.
    public static IReadOnlyList<ProjectChoice> Choices(IReadOnlyList<ConnectionProject> projects, IEnumerable<Guid?> current)
    {
        ArgumentNullException.ThrowIfNull(projects);
        ArgumentNullException.ThrowIfNull(current);
        var held = current.Distinct().ToList();
        bool IsCurrent(Guid? id) => held.Count == 1 && held[0] == id;
        return
        [
            new ProjectChoice(null, null, IsCurrent(null)),
            .. projects.Select(project => new ProjectChoice(project.Id, project.Name, IsCurrent(project.Id))),
        ];
    }

    // A new connection picks among the active project's groups, an edited one among its own project's.
    public static Guid? FormScope(SavedConnection? existing, Guid? active) =>
        existing is null ? active : existing.ProjectId;

    // The project the core takes as "before" to move one a step up or down; false at either end.
    public static bool TryStep(IReadOnlyList<ConnectionProject> projects, Guid id, bool up, out Guid? before)
    {
        ArgumentNullException.ThrowIfNull(projects);
        before = null;
        var index = -1;
        for (var at = 0; at < projects.Count; at++)
        {
            if (projects[at].Id == id)
            {
                index = at;
                break;
            }
        }

        if (index < 0 || (up ? index == 0 : index == projects.Count - 1))
        {
            return false;
        }

        if (up)
        {
            before = projects[index - 1].Id;
        }
        else if (index + 2 < projects.Count)
        {
            before = projects[index + 2].Id;
        }

        return true;
    }
}
