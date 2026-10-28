namespace TablePro.Storage.Connections;

/// <summary>
/// The format 2 consistency checks of the macOS <c>BundleViolation</c>: every ref is present and unique within its
/// kind, every link resolves, credentials belong to a connection in the file, and group and folder trees have no
/// cycle and are at most 32 deep, so a crafted file cannot loop the import or build absurd paths.
/// </summary>
internal static class ConnectionBundleValidation
{
    public const int MaximumNestingDepth = 32;

    /// <summary>The first problem, worded for "This file is not a valid TablePro export: ...", or null.</summary>
    public static string? FirstViolation(PortableConnectionFile file)
    {
        var connections = file.Connections.Select(c => c.Ref).ToList();
        var groups = (file.Groups ?? []).Select(g => g.Ref).ToList();
        var profiles = (file.CredentialProfiles ?? []).Select(p => p.Ref).ToList();
        var folders = (file.QueryFolders ?? []).Select(f => (string?)f.Ref).ToList();
        var queries = (file.SavedQueries ?? []).Select(q => (string?)q.Ref).ToList();
        foreach (var refs in new[] { connections, groups, profiles, folders, queries })
        {
            if (IdentityViolation(refs) is { } identity)
            {
                return identity;
            }
        }

        var connectionRefs = connections.ToHashSet(StringComparer.Ordinal);
        var groupRefs = groups.ToHashSet(StringComparer.Ordinal);
        var profileRefs = profiles.ToHashSet(StringComparer.Ordinal);
        var folderRefs = folders.ToHashSet(StringComparer.Ordinal);

        var links = new List<(string? Ref, string? Referrer, HashSet<string?> Targets)>();
        foreach (var connection in file.Connections)
        {
            links.Add((connection.GroupRef, connection.Ref, groupRefs));
            links.Add((connection.CredentialProfileRef, connection.Ref, profileRefs));
        }

        foreach (var group in file.Groups ?? [])
        {
            links.Add((group.ParentRef, group.Ref, groupRefs));
        }

        foreach (var folder in file.QueryFolders ?? [])
        {
            links.Add((folder.ParentRef, folder.Ref, folderRefs));
            links.Add((folder.ConnectionRef, folder.Ref, connectionRefs));
        }

        foreach (var query in file.SavedQueries ?? [])
        {
            links.Add((query.FolderRef, query.Ref, folderRefs));
            links.Add((query.ConnectionRef, query.Ref, connectionRefs));
        }

        foreach (var (target, referrer, targets) in links)
        {
            if (target is not null && !targets.Contains(target))
            {
                return $"“{referrer}” refers to “{target}”, which is not in the file";
            }
        }

        if ((file.Credentials ?? []).Keys.Order(StringComparer.Ordinal).FirstOrDefault(k => !connectionRefs.Contains(k)) is { } orphan)
        {
            return $"the passwords for “{orphan}” belong to no connection in the file";
        }

        var groupParents = ParentMap((file.Groups ?? []).Select(g => (g.Ref!, g.ParentRef)));
        var folderParents = ParentMap((file.QueryFolders ?? []).Select(f => (f.Ref, f.ParentRef)));
        if ((FirstCycle(groupParents) ?? FirstCycle(folderParents)) is { } cycle)
        {
            return $"the reference “{cycle}” is inside itself";
        }

        if ((FirstTooDeep(groupParents) ?? FirstTooDeep(folderParents)) is { } deep)
        {
            return $"the reference “{deep}” is nested too deeply";
        }

        return null;
    }

    private static string? IdentityViolation(List<string?> refs)
    {
        var seen = new HashSet<string>(StringComparer.Ordinal);
        foreach (var value in refs)
        {
            if (string.IsNullOrWhiteSpace(value))
            {
                return "an item has an empty reference";
            }

            if (!seen.Add(value))
            {
                return $"the reference “{value}” is used more than once";
            }
        }

        return null;
    }

    private static Dictionary<string, string?> ParentMap(IEnumerable<(string Ref, string? Parent)> nodes)
    {
        var map = new Dictionary<string, string?>(StringComparer.Ordinal);
        foreach (var (node, parent) in nodes)
        {
            map.TryAdd(node, parent);
        }

        return map;
    }

    private static string? FirstCycle(Dictionary<string, string?> parents)
    {
        var acyclic = new HashSet<string>(StringComparer.Ordinal);
        foreach (var start in parents.Keys)
        {
            var path = new HashSet<string>(StringComparer.Ordinal);
            for (var current = start; current is not null && !acyclic.Contains(current); current = parents.GetValueOrDefault(current))
            {
                if (!path.Add(current))
                {
                    return current;
                }
            }

            acyclic.UnionWith(path);
        }

        return null;
    }

    /// <summary>Runs after the cycle check, so every parent chain ends.</summary>
    private static string? FirstTooDeep(Dictionary<string, string?> parents)
    {
        var depths = new Dictionary<string, int>(StringComparer.Ordinal);
        foreach (var start in parents.Keys)
        {
            var path = new List<string>();
            var depthBelow = 0;
            for (var current = start; current is not null; current = parents.GetValueOrDefault(current))
            {
                if (depths.TryGetValue(current, out var known))
                {
                    depthBelow = known;
                    break;
                }

                path.Add(current);
            }

            for (var i = path.Count - 1; i >= 0; i--)
            {
                var depth = depthBelow + (path.Count - i);
                if (depth > MaximumNestingDepth)
                {
                    return start;
                }

                depths[path[i]] = depth;
            }
        }

        return null;
    }
}
