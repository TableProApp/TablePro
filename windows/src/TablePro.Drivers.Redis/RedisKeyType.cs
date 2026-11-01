namespace TablePro.Drivers.Redis;

internal enum RedisKeyType
{
    None,
    String,
    Hash,
    List,
    Set,
    SortedSet,
    Stream,
    Json,
    Other,
}

internal static class RedisKeyTypes
{
    /// <summary>The <c>TYPE</c> reply's name; ReJSON reports its module type <c>ReJSON-RL</c>.</summary>
    public static RedisKeyType Parse(string? name) => name?.Trim().ToLowerInvariant() switch
    {
        null or "" or "none" => RedisKeyType.None,
        "string" => RedisKeyType.String,
        "hash" => RedisKeyType.Hash,
        "list" => RedisKeyType.List,
        "set" => RedisKeyType.Set,
        "zset" => RedisKeyType.SortedSet,
        "stream" => RedisKeyType.Stream,
        "rejson-rl" or "json" => RedisKeyType.Json,
        _ => RedisKeyType.Other,
    };

    /// <summary>The command that counts a key's rows, or <see langword="null"/> when the key is one row.</summary>
    public static string? LengthCommand(RedisKeyType type) => type switch
    {
        RedisKeyType.Hash => "HLEN",
        RedisKeyType.List => "LLEN",
        RedisKeyType.Set => "SCARD",
        RedisKeyType.SortedSet => "ZCARD",
        RedisKeyType.Stream => "XLEN",
        _ => null,
    };

    public static bool IsBrowsable(RedisKeyType type) => type is not (RedisKeyType.None or RedisKeyType.Other);
}
