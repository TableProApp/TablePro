using System.Text.Json.Serialization;

namespace TablePro.Drivers.Etcd;

// The etcd v3 JSON gateway writes protobuf JSON: int64 fields as strings, bytes as base64, and fields at their
// default (zero, false, empty) left out. byte[] properties take base64 in both directions, and number handling reads
// the quoted integers.

internal sealed class EtcdHeader
{
    public ulong ClusterId { get; set; }

    public ulong MemberId { get; set; }

    public long Revision { get; set; }

    public ulong RaftTerm { get; set; }
}

internal sealed class EtcdKeyValue
{
    public byte[]? Key { get; set; }

    public byte[]? Value { get; set; }

    public long CreateRevision { get; set; }

    public long ModRevision { get; set; }

    public long Version { get; set; }

    public long Lease { get; set; }
}

internal sealed class EtcdRangeRequest
{
    public byte[]? Key { get; set; }

    public byte[]? RangeEnd { get; set; }

    public long Limit { get; set; }

    public long Revision { get; set; }

    public string? SortOrder { get; set; }

    public string? SortTarget { get; set; }

    public bool KeysOnly { get; set; }

    public bool CountOnly { get; set; }
}

internal sealed class EtcdRangeResponse
{
    public EtcdHeader? Header { get; set; }

    public List<EtcdKeyValue>? Kvs { get; set; }

    public bool More { get; set; }

    public long Count { get; set; }
}

internal sealed class EtcdPutRequest
{
    public byte[]? Key { get; set; }

    public byte[]? Value { get; set; }

    public long Lease { get; set; }

    public bool IgnoreValue { get; set; }

    public bool IgnoreLease { get; set; }
}

internal sealed class EtcdPutResponse
{
    public EtcdHeader? Header { get; set; }
}

internal sealed class EtcdDeleteRangeRequest
{
    public byte[]? Key { get; set; }

    public byte[]? RangeEnd { get; set; }
}

internal sealed class EtcdDeleteRangeResponse
{
    public EtcdHeader? Header { get; set; }

    public long Deleted { get; set; }
}

internal sealed class EtcdCompare
{
    public string Result { get; set; } = "EQUAL";

    public string Target { get; set; } = "VERSION";

    public byte[]? Key { get; set; }

    // Nullable so zero is still written ("version equals 0" proves a key is absent) while the unused one of the
    // target oneof is left out, which the gateway requires.
    public long? Version { get; set; }

    public long? ModRevision { get; set; }
}

internal sealed class EtcdRequestOp
{
    public EtcdPutRequest? RequestPut { get; set; }

    public EtcdDeleteRangeRequest? RequestDeleteRange { get; set; }
}

internal sealed class EtcdTxnRequest
{
    public List<EtcdCompare> Compare { get; set; } = [];

    public List<EtcdRequestOp> Success { get; set; } = [];

    public List<EtcdRequestOp> Failure { get; set; } = [];
}

internal sealed class EtcdTxnResponse
{
    public EtcdHeader? Header { get; set; }

    public bool Succeeded { get; set; }
}

internal sealed class EtcdLeaseRequest
{
    [JsonPropertyName("ID")]
    public long Id { get; set; }

    [JsonPropertyName("TTL")]
    public long Ttl { get; set; }

    public bool Keys { get; set; }
}

internal sealed class EtcdLeaseResponse
{
    public EtcdHeader? Header { get; set; }

    [JsonPropertyName("ID")]
    public long Id { get; set; }

    [JsonPropertyName("TTL")]
    public long Ttl { get; set; }

    [JsonPropertyName("grantedTTL")]
    public long GrantedTtl { get; set; }

    public List<byte[]>? Keys { get; set; }

    public string? Error { get; set; }
}

internal sealed class EtcdKeepAliveLine
{
    public EtcdLeaseResponse? Result { get; set; }
}

internal sealed class EtcdLeaseStatus
{
    [JsonPropertyName("ID")]
    public long Id { get; set; }
}

internal sealed class EtcdLeasesResponse
{
    public List<EtcdLeaseStatus>? Leases { get; set; }
}

internal sealed class EtcdMember
{
    [JsonPropertyName("ID")]
    public ulong Id { get; set; }

    public string? Name { get; set; }

    [JsonPropertyName("peerURLs")]
    public List<string>? PeerUrls { get; set; }

    [JsonPropertyName("clientURLs")]
    public List<string>? ClientUrls { get; set; }

    [JsonPropertyName("isLearner")]
    public bool IsLearner { get; set; }
}

internal sealed class EtcdMemberListResponse
{
    public EtcdHeader? Header { get; set; }

    public List<EtcdMember>? Members { get; set; }
}

internal sealed class EtcdStatusResponse
{
    public EtcdHeader? Header { get; set; }

    public string? Version { get; set; }

    [JsonPropertyName("dbSize")]
    public long DbSize { get; set; }

    [JsonPropertyName("dbSizeInUse")]
    public long DbSizeInUse { get; set; }

    public ulong Leader { get; set; }

    [JsonPropertyName("raftIndex")]
    public ulong RaftIndex { get; set; }

    [JsonPropertyName("raftTerm")]
    public ulong RaftTerm { get; set; }

    [JsonPropertyName("isLearner")]
    public bool IsLearner { get; set; }

    public List<string>? Errors { get; set; }
}

internal sealed class EtcdCompactionRequest
{
    public long Revision { get; set; }

    public bool Physical { get; set; }
}

internal sealed class EtcdAuthRequest
{
    public string? Name { get; set; }

    public string? Password { get; set; }

    public string? Role { get; set; }

    public string? User { get; set; }
}

internal sealed class EtcdAuthResponse
{
    public string? Token { get; set; }

    public List<string>? Users { get; set; }

    public List<string>? Roles { get; set; }
}

internal sealed class EtcdEmpty;

internal sealed class EtcdWatchCreate
{
    public byte[]? Key { get; set; }

    public byte[]? RangeEnd { get; set; }
}

internal sealed class EtcdWatchRequest
{
    public EtcdWatchCreate? CreateRequest { get; set; }
}

internal sealed class EtcdEvent
{
    // PUT is the enum's zero, which protobuf JSON leaves out.
    public string? Type { get; set; }

    public EtcdKeyValue? Kv { get; set; }
}

internal sealed class EtcdWatchResult
{
    public List<EtcdEvent>? Events { get; set; }
}

internal sealed class EtcdWatchLine
{
    public EtcdWatchResult? Result { get; set; }
}

internal sealed class EtcdErrorBody
{
    public string? Error { get; set; }

    public int Code { get; set; }

    public string? Message { get; set; }
}

internal sealed class EtcdVersionResponse
{
    public string? Etcdserver { get; set; }
}

[JsonSourceGenerationOptions(
    PropertyNamingPolicy = JsonKnownNamingPolicy.SnakeCaseLower,
    PropertyNameCaseInsensitive = true,
    NumberHandling = JsonNumberHandling.AllowReadingFromString,
    DefaultIgnoreCondition = JsonIgnoreCondition.WhenWritingDefault)]
[JsonSerializable(typeof(EtcdRangeRequest))]
[JsonSerializable(typeof(EtcdRangeResponse))]
[JsonSerializable(typeof(EtcdPutRequest))]
[JsonSerializable(typeof(EtcdPutResponse))]
[JsonSerializable(typeof(EtcdDeleteRangeRequest))]
[JsonSerializable(typeof(EtcdDeleteRangeResponse))]
[JsonSerializable(typeof(EtcdTxnRequest))]
[JsonSerializable(typeof(EtcdTxnResponse))]
[JsonSerializable(typeof(EtcdLeaseRequest))]
[JsonSerializable(typeof(EtcdLeaseResponse))]
[JsonSerializable(typeof(EtcdKeepAliveLine))]
[JsonSerializable(typeof(EtcdLeasesResponse))]
[JsonSerializable(typeof(EtcdMemberListResponse))]
[JsonSerializable(typeof(EtcdStatusResponse))]
[JsonSerializable(typeof(EtcdCompactionRequest))]
[JsonSerializable(typeof(EtcdAuthRequest))]
[JsonSerializable(typeof(EtcdAuthResponse))]
[JsonSerializable(typeof(EtcdEmpty))]
[JsonSerializable(typeof(EtcdWatchRequest))]
[JsonSerializable(typeof(EtcdWatchLine))]
[JsonSerializable(typeof(EtcdErrorBody))]
[JsonSerializable(typeof(EtcdVersionResponse))]
internal sealed partial class EtcdJsonContext : JsonSerializerContext;
