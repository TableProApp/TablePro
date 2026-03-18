/*
  Copyright (c) DataStax, Inc.

  Licensed under the Apache License, Version 2.0 (the "License");
  you may not use this file except in compliance with the License.
  You may obtain a copy of the License at

  http://www.apache.org/licenses/LICENSE-2.0

  Unless required by applicable law or agreed to in writing, software
  distributed under the License is distributed on an "AS IS" BASIS,
  WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
  See the License for the specific language governing permissions and
  limitations under the License.
*/

#ifndef __CASSANDRA_H_INCLUDED__
#define __CASSANDRA_H_INCLUDED__

#include <stddef.h>
#include <stdint.h>

#if !defined(CASS_STATIC)
#  if (defined(WIN32) || defined(_WIN32))
#    if defined(CASS_BUILDING)
#      define CASS_EXPORT __declspec(dllexport)
#    else
#      define CASS_EXPORT __declspec(dllimport)
#    endif
#  elif (defined(__SUNPRO_C)  || defined(__SUNPRO_CC)) && !defined(CASS_STATIC)
#    define CASS_EXPORT __global
#  elif (defined(__GNUC__) && __GNUC__ >= 4) || defined(__INTEL_COMPILER)
#    define CASS_EXPORT __attribute__ ((visibility("default")))
#  endif
#else
#define CASS_EXPORT
#endif

#if defined(_MSC_VER)
#  define CASS_DEPRECATED(func) __declspec(deprecated) func
#elif defined(__GNUC__) || defined(__INTEL_COMPILER)
#  define CASS_DEPRECATED(func) func __attribute__((deprecated))
#else
#  define CASS_DEPRECATED(func) func
#endif

/**
 * @file include/cassandra.h
 *
 * C/C++ driver for Apache Cassandra. Uses the Cassandra Query Language versions 3
 * over the Cassandra Binary Protocol (versions 1, 2, or 3).
 */

#define CASS_VERSION_MAJOR 2
#define CASS_VERSION_MINOR 17
#define CASS_VERSION_PATCH 1
#define CASS_VERSION_SUFFIX ""

#ifdef __cplusplus
extern "C" {
#endif

typedef enum { cass_false = 0, cass_true = 1 } cass_bool_t;

typedef float cass_float_t;
typedef double cass_double_t;

typedef int8_t cass_int8_t;
typedef uint8_t cass_uint8_t;

typedef int16_t cass_int16_t;
typedef uint16_t cass_uint16_t;

typedef int32_t cass_int32_t;
typedef uint32_t cass_uint32_t;

typedef int64_t cass_int64_t;
typedef uint64_t cass_uint64_t;

#define CASS_UINT64_MAX 18446744073709551615ULL

typedef cass_uint8_t cass_byte_t;
typedef cass_uint64_t cass_duration_t;

/**
 * The size of an IPv4 address
 */
#define CASS_INET_V4_LENGTH 4

/**
 * The size of an IPv6 address
 */
#define CASS_INET_V6_LENGTH 16

/**
 * The size of an inet string including a null terminator.
 */
#define CASS_INET_STRING_LENGTH 46

/**
 * IP address for either IPv4 or IPv6.
 *
 * @struct CassInet
 */
typedef struct CassInet_ {
  /**
   * Big-endian, binary representation of a IPv4 or IPv6 address
   */
  cass_uint8_t address[CASS_INET_V6_LENGTH];
  /**
   * Number of address bytes. 4 bytes for IPv4 and 16 bytes for IPv6.
   */
  cass_uint8_t address_length;
} CassInet;

/**
 * The size of a hexadecimal UUID string including a null terminator.
 */
#define CASS_UUID_STRING_LENGTH 37

/**
 * Version 1 (time-based) or version 4 (random) UUID.
 *
 * @struct CassUuid
 */
typedef struct CassUuid_ {
  /**
   * Represents the time and version part of a UUID. The most significant
   * 4 bits represent the version and the bottom 60 bits representing the
   * time part. For version 1 the time part represents the number of
   * 100 nanosecond periods since 00:00:00 UTC, January 1, 1970 (the Epoch).
   * For version 4 the time part is randomly generated.
   */
  cass_uint64_t time_and_version;
  /**
   * Represents the clock sequence and the node part of a UUID. The most
   * significant 16 bits represent the clock sequence (except for the most
   * significant bit which is always set) and the bottom 48 bits represent
   * the node part. For version 1 (time-based) the clock sequence part is randomly
   * generated and the node part can be explicitly set, otherwise, it's generated
   * from node unique information. For version 4 both the clock sequence and the node
   * parts are randomly generated.
   */
  cass_uint64_t clock_seq_and_node;
} CassUuid;

/**
 * A cluster object describes the configuration of the Cassandra cluster and is used
 * to construct a session instance. Unlike other DataStax drivers the cluster object
 * does not maintain the control connection.
 *
 * @struct CassCluster
 */
typedef struct CassCluster_ CassCluster;

/**
 * A session object is used to execute queries and maintains cluster state through
 * the control connection. The control connection is used to auto-discover nodes and
 * monitor cluster changes (topology and schema). Each session also maintains multiple
 * pools of connections to cluster nodes which are used to query the cluster.
 *
 * Instances of the session object are thread-safe to execute queries.
 *
 * @struct CassSession
 */
typedef struct CassSession_ CassSession;

/**
 * A statement object is an executable query. It represents either a regular
 * (adhoc) statement or a prepared statement. It maintains the queries' parameter
 * values along with query options (consistency level, paging state, etc.)
 *
 * <b>Note:</b> Parameters for regular queries are not supported by the binary protocol
 * version 1.
 *
 * @struct CassStatement
 */
typedef struct CassStatement_ CassStatement;

/**
 * A group of statements that are executed as a single batch.
 *
 * <b>Note:</b> Batches are not supported by the binary protocol version 1.
 *
 * @cassandra{2.0+}
 *
 * @struct CassBatch
 */
typedef struct CassBatch_ CassBatch;

/**
 * The future result of an operation.
 *
 * It can represent a result if the operation completed successfully or an
 * error if the operation failed. It can be waited on, polled or a callback
 * can be attached.
 *
 * @struct CassFuture
 */
typedef struct CassFuture_ CassFuture;

/**
 * A statement that has been prepared cluster-side (It has been pre-parsed
 * and cached).
 *
 * A prepared statement is read-only and it is thread-safe to concurrently
 * bind new statements.
 *
 * @struct CassPrepared
 */
typedef struct CassPrepared_ CassPrepared;

/**
 * The result of a query.
 *
 * A result object is read-only and is thread-safe to read or iterate over
 * concurrently.
 *
 * @struct CassResult
 */
typedef struct CassResult_ CassResult;

/**
 * A error result of a request
 *
 * @struct CassErrorResult
 */
typedef struct CassErrorResult_ CassErrorResult;


/**
 * An object that represents a cluster node.
 *
 * @struct CassNode
 */
typedef struct CassNode_ CassNode;

/**
 * An object used to iterate over a group of rows, columns or collection values.
 *
 * @struct CassIterator
 */
typedef struct CassIterator_ CassIterator;

/**
 * A collection of column values.
 *
 * @struct CassRow
 */
typedef struct CassRow_ CassRow;

/**
 * A single primitive value or a collection of values.
 *
 * @struct CassValue
 */
typedef struct CassValue_ CassValue;

/**
 * A data type used to describe a value, collection or
 * user defined type.
 *
 * @struct CassDataType
 */
typedef struct CassDataType_ CassDataType;

/**
 * @struct CassFunctionMeta
 *
 * @cassandra{2.2+}
 */
typedef struct CassFunctionMeta_ CassFunctionMeta;

/**
 * @struct CassAggregateMeta
 *
 * @cassandra{2.2+}
 */
typedef struct CassAggregateMeta_ CassAggregateMeta;

/**
 *  A collection of values.
 *
 * @struct CassCollection
 */
typedef struct CassCollection_ CassCollection;

/**
 * A tuple of values.
 *
 * @struct CassTuple
 *
 * @cassandra{2.1+}
 */
typedef struct CassTuple_ CassTuple;

/**
 * A user defined type.
 *
 * @struct CassUserType
 *
 * @cassandra{2.1+}
 */
typedef struct CassUserType_ CassUserType;

/**
 * Describes the SSL configuration of a cluster.
 *
 * @struct CassSsl
 */
typedef struct CassSsl_ CassSsl;

/**
 * Describes the version of the connected Cassandra cluster.
 *
 * @struct CassVersion
 */

typedef struct CassVersion_ {
  int major_version;
  int minor_version;
  int patch_version;
} CassVersion;

/**
 * A snapshot of the schema's metadata.
 *
 * @struct CassSchemaMeta
 */
typedef struct CassSchemaMeta_ CassSchemaMeta;

/**
 * Keyspace metadata
 *
 * @struct CassKeyspaceMeta
 */
typedef struct CassKeyspaceMeta_ CassKeyspaceMeta;

/**
 * Table metadata
 *
 * @struct CassTableMeta
 */
typedef struct CassTableMeta_ CassTableMeta;

/**
 * MaterializedView metadata
 *
 * @struct CassMaterializedViewMeta
 *
 * @cassandra{3.0+}
 */
typedef struct CassMaterializedViewMeta_ CassMaterializedViewMeta;

/**
 * Column metadata
 *
 * @struct CassColumnMeta
 */
typedef struct CassColumnMeta_ CassColumnMeta;

/**
 * Index metadata
 *
 * @struct CassIndexMeta
 */
typedef struct CassIndexMeta_ CassIndexMeta;

/**
 * A UUID generator object.
 *
 * Instances of the UUID generator object are thread-safe to generate UUIDs.
 *
 * @struct CassUuidGen
 */
typedef struct CassUuidGen_ CassUuidGen;

/**
 * Policies that defined the behavior of a request when a server-side
 * read/write timeout or unavailable error occurs.
 *
 * Generators of client-side, microsecond-precision timestamps.
 *
 * @struct CassTimestampGen
 *
 * @cassandra{2.1+}
 */
typedef struct CassTimestampGen_ CassTimestampGen;

/**
 * @struct CassRetryPolicy
 */
typedef struct CassRetryPolicy_ CassRetryPolicy;

/**
 * @struct CassCustomPayload
 *
 * @cassandra{2.2+}
 */
typedef struct CassCustomPayload_ CassCustomPayload;

/**
 * A snapshot of the session's performance/diagnostic metrics.
 *
 * @struct CassMetrics
 */
typedef struct CassMetrics_ {
  struct {
    cass_uint64_t min; /**< Minimum in microseconds */
    cass_uint64_t max; /**< Maximum in microseconds */
    cass_uint64_t mean; /**< Mean in microseconds */
    cass_uint64_t stddev; /**< Standard deviation in microseconds */
    cass_uint64_t median; /**< Median in microseconds */
    cass_uint64_t percentile_75th; /**< 75th percentile in microseconds */
    cass_uint64_t percentile_95th; /**< 95th percentile in microseconds */
    cass_uint64_t percentile_98th; /**< 98th percentile in microseconds */
    cass_uint64_t percentile_99th; /**< 99the percentile in microseconds */
    cass_uint64_t percentile_999th; /**< 99.9th percentile in microseconds */
    cass_double_t mean_rate; /**<  Mean rate in requests per second */
    cass_double_t one_minute_rate; /**< 1 minute rate in requests per second */
    cass_double_t five_minute_rate; /**<  5 minute rate in requests per second */
    cass_double_t fifteen_minute_rate; /**< 15 minute rate in requests per second */
  } requests; /**< Performance request metrics */

  struct {
    cass_uint64_t total_connections; /**< The total number of connections */
    cass_uint64_t available_connections; /**< Deprecated */
    cass_uint64_t exceeded_pending_requests_water_mark; /**< Deprecated */
    cass_uint64_t exceeded_write_bytes_water_mark; /**< Deprecated */
  } stats; /**< Diagnostic metrics */

  struct {
    cass_uint64_t connection_timeouts; /**< Occurrences of a connection timeout */
    cass_uint64_t pending_request_timeouts; /**< Deprecated */
    cass_uint64_t request_timeouts; /**< Occurrences of requests that timed out waiting for a request to finish */
  } errors; /**< Error metrics */
} CassMetrics;

typedef struct CassSpeculativeExecutionMetrics_ {
  cass_uint64_t min; /**< Minimum in microseconds */
  cass_uint64_t max; /**< Maximum in microseconds */
  cass_uint64_t mean; /**< Mean in microseconds */
  cass_uint64_t stddev; /**< Standard deviation in microseconds */
  cass_uint64_t median; /**< Median in microseconds */
  cass_uint64_t percentile_75th; /**< 75th percentile in microseconds */
  cass_uint64_t percentile_95th; /**< 95th percentile in microseconds */
  cass_uint64_t percentile_98th; /**< 98th percentile in microseconds */
  cass_uint64_t percentile_99th; /**< 99the percentile in microseconds */
  cass_uint64_t percentile_999th; /**< 99.9th percentile in microseconds */
  cass_uint64_t count; /**< The number of aborted speculative retries */
  cass_double_t percentage; /**< Fraction of requests that are aborted speculative retries */
} CassSpeculativeExecutionMetrics;

typedef enum CassConsistency_ {
  CASS_CONSISTENCY_UNKNOWN      = 0xFFFF,
  CASS_CONSISTENCY_ANY          = 0x0000,
  CASS_CONSISTENCY_ONE          = 0x0001,
  CASS_CONSISTENCY_TWO          = 0x0002,
  CASS_CONSISTENCY_THREE        = 0x0003,
  CASS_CONSISTENCY_QUORUM       = 0x0004,
  CASS_CONSISTENCY_ALL          = 0x0005,
  CASS_CONSISTENCY_LOCAL_QUORUM = 0x0006,
  CASS_CONSISTENCY_EACH_QUORUM  = 0x0007,
  CASS_CONSISTENCY_SERIAL       = 0x0008,
  CASS_CONSISTENCY_LOCAL_SERIAL = 0x0009,
  CASS_CONSISTENCY_LOCAL_ONE    = 0x000A
} CassConsistency;

#define CASS_CONSISTENCY_MAPPING(XX) \
  XX(CASS_CONSISTENCY_UNKNOWN, "UNKNOWN") \
  XX(CASS_CONSISTENCY_ANY, "ANY") \
  XX(CASS_CONSISTENCY_ONE, "ONE") \
  XX(CASS_CONSISTENCY_TWO, "TWO") \
  XX(CASS_CONSISTENCY_THREE, "THREE") \
  XX(CASS_CONSISTENCY_QUORUM, "QUORUM") \
  XX(CASS_CONSISTENCY_ALL, "ALL") \
  XX(CASS_CONSISTENCY_LOCAL_QUORUM, "LOCAL_QUORUM") \
  XX(CASS_CONSISTENCY_EACH_QUORUM, "EACH_QUORUM") \
  XX(CASS_CONSISTENCY_SERIAL, "SERIAL") \
  XX(CASS_CONSISTENCY_LOCAL_SERIAL, "LOCAL_SERIAL") \
  XX(CASS_CONSISTENCY_LOCAL_ONE, "LOCAL_ONE")

/* @cond IGNORE */
#define CASS_CONSISTENCY_MAP CASS_CONSISTENCY_MAPPING /* Deprecated */
/* @endcond */

typedef enum CassWriteType_ {
  CASS_WRITE_TYPE_UNKNOWN,
  CASS_WRITE_TYPE_SIMPLE,
  CASS_WRITE_TYPE_BATCH,
  CASS_WRITE_TYPE_UNLOGGED_BATCH,
  CASS_WRITE_TYPE_COUNTER,
  CASS_WRITE_TYPE_BATCH_LOG,
  CASS_WRITE_TYPE_CAS,
  CASS_WRITE_TYPE_VIEW,
  CASS_WRITE_TYPE_CDC
} CassWriteType;

#define CASS_WRITE_TYPE_MAPPING(XX) \
  XX(CASS_WRITE_TYPE_SIMPLE, "SIMPLE") \
  XX(CASS_WRITE_TYPE_BATCH, "BATCH") \
  XX(CASS_WRITE_TYPE_UNLOGGED_BATCH, "UNLOGGED_BATCH") \
  XX(CASS_WRITE_TYPE_COUNTER, "COUNTER") \
  XX(CASS_WRITE_TYPE_BATCH_LOG, "BATCH_LOG") \
  XX(CASS_WRITE_TYPE_CAS, "CAS") \
  XX(CASS_WRITE_TYPE_VIEW, "VIEW") \
  XX(CASS_WRITE_TYPE_CDC, "CDC")

/* @cond IGNORE */
#define CASS_WRITE_TYPE_MAP CASS_WRITE_TYPE_MAPPING /* Deprecated */
/* @endcond */

typedef enum CassColumnType_ {
  CASS_COLUMN_TYPE_REGULAR,
  CASS_COLUMN_TYPE_PARTITION_KEY,
  CASS_COLUMN_TYPE_CLUSTERING_KEY,
  CASS_COLUMN_TYPE_STATIC,
  CASS_COLUMN_TYPE_COMPACT_VALUE
} CassColumnType;

typedef enum CassIndexType_ {
  CASS_INDEX_TYPE_UNKNOWN,
  CASS_INDEX_TYPE_KEYS,
  CASS_INDEX_TYPE_CUSTOM,
  CASS_INDEX_TYPE_COMPOSITES
} CassIndexType;

#define CASS_VALUE_TYPE_MAPPING(XX) \
  XX(CASS_VALUE_TYPE_CUSTOM,  0x0000, "", "") \
  XX(CASS_VALUE_TYPE_ASCII,  0x0001, "ascii", "org.apache.cassandra.db.marshal.AsciiType") \
  XX(CASS_VALUE_TYPE_BIGINT,  0x0002, "bigint", "org.apache.cassandra.db.marshal.LongType") \
  XX(CASS_VALUE_TYPE_BLOB,  0x0003, "blob", "org.apache.cassandra.db.marshal.BytesType") \
  XX(CASS_VALUE_TYPE_BOOLEAN,  0x0004, "boolean", "org.apache.cassandra.db.marshal.BooleanType") \
  XX(CASS_VALUE_TYPE_COUNTER,  0x0005, "counter", "org.apache.cassandra.db.marshal.CounterColumnType") \
  XX(CASS_VALUE_TYPE_DECIMAL,  0x0006, "decimal", "org.apache.cassandra.db.marshal.DecimalType") \
  XX(CASS_VALUE_TYPE_DOUBLE,  0x0007, "double", "org.apache.cassandra.db.marshal.DoubleType") \
  XX(CASS_VALUE_TYPE_FLOAT,  0x0008, "float", "org.apache.cassandra.db.marshal.FloatType") \
  XX(CASS_VALUE_TYPE_INT,  0x0009, "int", "org.apache.cassandra.db.marshal.Int32Type") \
  XX(CASS_VALUE_TYPE_TEXT,  0x000A, "text", "org.apache.cassandra.db.marshal.UTF8Type") \
  XX(CASS_VALUE_TYPE_TIMESTAMP,  0x000B, "timestamp", "org.apache.cassandra.db.marshal.TimestampType") \
  XX(CASS_VALUE_TYPE_UUID,  0x000C, "uuid", "org.apache.cassandra.db.marshal.UUIDType") \
  XX(CASS_VALUE_TYPE_VARCHAR,  0x000D, "varchar", "") \
  XX(CASS_VALUE_TYPE_VARINT,  0x000E, "varint", "org.apache.cassandra.db.marshal.IntegerType") \
  XX(CASS_VALUE_TYPE_TIMEUUID,  0x000F, "timeuuid", "org.apache.cassandra.db.marshal.TimeUUIDType") \
  XX(CASS_VALUE_TYPE_INET,  0x0010, "inet", "org.apache.cassandra.db.marshal.InetAddressType") \
  XX(CASS_VALUE_TYPE_DATE,  0x0011, "date", "org.apache.cassandra.db.marshal.SimpleDateType") \
  XX(CASS_VALUE_TYPE_TIME,  0x0012, "time", "org.apache.cassandra.db.marshal.TimeType") \
  XX(CASS_VALUE_TYPE_SMALL_INT,  0x0013, "smallint", "org.apache.cassandra.db.marshal.ShortType") \
  XX(CASS_VALUE_TYPE_TINY_INT,  0x0014, "tinyint", "org.apache.cassandra.db.marshal.ByteType") \
  XX(CASS_VALUE_TYPE_DURATION,  0x0015, "duration", "org.apache.cassandra.db.marshal.DurationType") \
  XX(CASS_VALUE_TYPE_LIST,  0x0020, "list", "org.apache.cassandra.db.marshal.ListType") \
  XX(CASS_VALUE_TYPE_MAP,  0x0021, "map", "org.apache.cassandra.db.marshal.MapType") \
  XX(CASS_VALUE_TYPE_SET,  0x0022, "set", "org.apache.cassandra.db.marshal.SetType") \
  XX(CASS_VALUE_TYPE_UDT,  0x0030, "", "") \
  XX(CASS_VALUE_TYPE_TUPLE,  0x0031, "tuple", "org.apache.cassandra.db.marshal.TupleType")

typedef enum CassValueType_ {
  CASS_VALUE_TYPE_UNKNOWN = 0xFFFF,
#define XX_VALUE_TYPE(name, type, cql, klass) name = type,
  CASS_VALUE_TYPE_MAPPING(XX_VALUE_TYPE)
#undef XX_VALUE_TYPE
  /* @cond IGNORE */
  CASS_VALUE_TYPE_LAST_ENTRY
  /* @endcond */
} CassValueType;

typedef enum CassClusteringOrder_ {
  CASS_CLUSTERING_ORDER_NONE,
  CASS_CLUSTERING_ORDER_ASC,
  CASS_CLUSTERING_ORDER_DESC
} CassClusteringOrder;

typedef enum CassCollectionType_ {
  CASS_COLLECTION_TYPE_LIST = CASS_VALUE_TYPE_LIST,
  CASS_COLLECTION_TYPE_MAP  = CASS_VALUE_TYPE_MAP,
  CASS_COLLECTION_TYPE_SET  = CASS_VALUE_TYPE_SET
} CassCollectionType;

typedef enum CassBatchType_ {
  CASS_BATCH_TYPE_LOGGED   = 0x00,
  CASS_BATCH_TYPE_UNLOGGED = 0x01,
  CASS_BATCH_TYPE_COUNTER  = 0x02
} CassBatchType;

typedef enum CassIteratorType_ {
  CASS_ITERATOR_TYPE_RESULT,
  CASS_ITERATOR_TYPE_ROW,
  CASS_ITERATOR_TYPE_COLLECTION,
  CASS_ITERATOR_TYPE_MAP,
  CASS_ITERATOR_TYPE_TUPLE,
  CASS_ITERATOR_TYPE_USER_TYPE_FIELD,
  CASS_ITERATOR_TYPE_META_FIELD,
  CASS_ITERATOR_TYPE_KEYSPACE_META,
  CASS_ITERATOR_TYPE_TABLE_META,
  CASS_ITERATOR_TYPE_TYPE_META,
  CASS_ITERATOR_TYPE_FUNCTION_META,
  CASS_ITERATOR_TYPE_AGGREGATE_META,
  CASS_ITERATOR_TYPE_COLUMN_META,
  CASS_ITERATOR_TYPE_INDEX_META,
  CASS_ITERATOR_TYPE_MATERIALIZED_VIEW_META
} CassIteratorType;

#define CASS_LOG_LEVEL_MAPPING(XX) \
  XX(CASS_LOG_DISABLED, "") \
  XX(CASS_LOG_CRITICAL, "CRITICAL") \
  XX(CASS_LOG_ERROR, "ERROR") \
  XX(CASS_LOG_WARN, "WARN") \
  XX(CASS_LOG_INFO, "INFO") \
  XX(CASS_LOG_DEBUG, "DEBUG") \
  XX(CASS_LOG_TRACE, "TRACE")

/* @cond IGNORE */
#define CASS_LOG_LEVEL_MAP CASS_LOG_LEVEL_MAPPING /* Deprecated */
/* @endcond */

typedef enum CassLogLevel_ {
#define XX_LOG(log_level, _) log_level,
  CASS_LOG_LEVEL_MAPPING(XX_LOG)
#undef XX_LOG
  /* @cond IGNORE */
  CASS_LOG_LAST_ENTRY
  /* @endcond */
} CassLogLevel;

typedef enum CassSslVerifyFlags_ {
  CASS_SSL_VERIFY_NONE              = 0x00,
  CASS_SSL_VERIFY_PEER_CERT         = 0x01,
  CASS_SSL_VERIFY_PEER_IDENTITY     = 0x02,
  CASS_SSL_VERIFY_PEER_IDENTITY_DNS = 0x04
} CassSslVerifyFlags;

typedef enum CassSslTlsVersion_ {
  CASS_SSL_VERSION_TLS1   = 0x00,
  CASS_SSL_VERSION_TLS1_1 = 0x01,
  CASS_SSL_VERSION_TLS1_2 = 0x02
} CassSslTlsVersion;

typedef enum CassProtocolVersion_ {
  CASS_PROTOCOL_VERSION_V1    = 0x01, /**< Deprecated */
  CASS_PROTOCOL_VERSION_V2    = 0x02, /**< Deprecated */
  CASS_PROTOCOL_VERSION_V3    = 0x03,
  CASS_PROTOCOL_VERSION_V4    = 0x04,
  CASS_PROTOCOL_VERSION_V5    = 0x05,
  CASS_PROTOCOL_VERSION_DSEV1 = 0x41, /**< Only supported when using the DSE
                                           driver with DataStax Enterprise */
  CASS_PROTOCOL_VERSION_DSEV2 = 0x42  /**< Only supported when using the DSE
                                           driver with DataStax Enterprise */
} CassProtocolVersion;

typedef enum  CassErrorSource_ {
  CASS_ERROR_SOURCE_NONE,
  CASS_ERROR_SOURCE_LIB,
  CASS_ERROR_SOURCE_SERVER,
  CASS_ERROR_SOURCE_SSL,
  CASS_ERROR_SOURCE_COMPRESSION
} CassErrorSource;

#define CASS_ERROR_MAPPING(XX) \
  XX(CASS_ERROR_SOURCE_LIB, CASS_ERROR_LIB_BAD_PARAMS, 1, "Bad parameters") \
  XX(CASS_ERROR_SOURCE_LIB, CASS_ERROR_LIB_NO_STREAMS, 2, "No streams available") \
  XX(CASS_ERROR_SOURCE_LIB, CASS_ERROR_LIB_UNABLE_TO_INIT, 3, "Unable to initialize") \
  XX(CASS_ERROR_SOURCE_LIB, CASS_ERROR_LIB_MESSAGE_ENCODE, 4, "Unable to encode message") \
  XX(CASS_ERROR_SOURCE_LIB, CASS_ERROR_LIB_HOST_RESOLUTION, 5, "Unable to resolve host") \
  XX(CASS_ERROR_SOURCE_LIB, CASS_ERROR_LIB_UNEXPECTED_RESPONSE, 6, "Unexpected response from server") \
  XX(CASS_ERROR_SOURCE_LIB, CASS_ERROR_LIB_REQUEST_QUEUE_FULL, 7, "The request queue is full") \
  XX(CASS_ERROR_SOURCE_LIB, CASS_ERROR_LIB_NO_AVAILABLE_IO_THREAD, 8, "No available IO threads") \
  XX(CASS_ERROR_SOURCE_LIB, CASS_ERROR_LIB_WRITE_ERROR, 9, "Write error") \
  XX(CASS_ERROR_SOURCE_LIB, CASS_ERROR_LIB_NO_HOSTS_AVAILABLE, 10, "No hosts available") \
  XX(CASS_ERROR_SOURCE_LIB, CASS_ERROR_LIB_INDEX_OUT_OF_BOUNDS, 11, "Index out of bounds") \
  XX(CASS_ERROR_SOURCE_LIB, CASS_ERROR_LIB_INVALID_ITEM_COUNT, 12, "Invalid item count") \
  XX(CASS_ERROR_SOURCE_LIB, CASS_ERROR_LIB_INVALID_VALUE_TYPE, 13, "Invalid value type") \
  XX(CASS_ERROR_SOURCE_LIB, CASS_ERROR_LIB_REQUEST_TIMED_OUT, 14, "Request timed out") \
  XX(CASS_ERROR_SOURCE_LIB, CASS_ERROR_LIB_UNABLE_TO_SET_KEYSPACE, 15, "Unable to set keyspace") \
  XX(CASS_ERROR_SOURCE_LIB, CASS_ERROR_LIB_CALLBACK_ALREADY_SET, 16, "Callback already set") \
  XX(CASS_ERROR_SOURCE_LIB, CASS_ERROR_LIB_INVALID_STATEMENT_TYPE, 17, "Invalid statement type") \
  XX(CASS_ERROR_SOURCE_LIB, CASS_ERROR_LIB_NAME_DOES_NOT_EXIST, 18, "No value or column for name") \
  XX(CASS_ERROR_SOURCE_LIB, CASS_ERROR_LIB_UNABLE_TO_DETERMINE_PROTOCOL, 19, "Unable to find supported protocol version") \
  XX(CASS_ERROR_SOURCE_LIB, CASS_ERROR_LIB_NULL_VALUE, 20, "NULL value specified") \
  XX(CASS_ERROR_SOURCE_LIB, CASS_ERROR_LIB_NOT_IMPLEMENTED, 21, "Not implemented") \
  XX(CASS_ERROR_SOURCE_LIB, CASS_ERROR_LIB_UNABLE_TO_CONNECT, 22, "Unable to connect") \
  XX(CASS_ERROR_SOURCE_LIB, CASS_ERROR_LIB_UNABLE_TO_CLOSE, 23, "Unable to close") \
  XX(CASS_ERROR_SOURCE_LIB, CASS_ERROR_LIB_NO_PAGING_STATE, 24, "No paging state") \
  XX(CASS_ERROR_SOURCE_LIB, CASS_ERROR_LIB_PARAMETER_UNSET, 25, "Parameter unset") \
  XX(CASS_ERROR_SOURCE_LIB, CASS_ERROR_LIB_INVALID_ERROR_RESULT_TYPE, 26, "Invalid error result type") \
  XX(CASS_ERROR_SOURCE_LIB, CASS_ERROR_LIB_INVALID_FUTURE_TYPE, 27, "Invalid future type") \
  XX(CASS_ERROR_SOURCE_LIB, CASS_ERROR_LIB_INTERNAL_ERROR, 28, "Internal error") \
  XX(CASS_ERROR_SOURCE_LIB, CASS_ERROR_LIB_INVALID_CUSTOM_TYPE, 29, "Invalid custom type") \
  XX(CASS_ERROR_SOURCE_LIB, CASS_ERROR_LIB_INVALID_DATA, 30, "Invalid data") \
  XX(CASS_ERROR_SOURCE_LIB, CASS_ERROR_LIB_NOT_ENOUGH_DATA, 31, "Not enough data") \
  XX(CASS_ERROR_SOURCE_LIB, CASS_ERROR_LIB_INVALID_STATE, 32, "Invalid state") \
  XX(CASS_ERROR_SOURCE_LIB, CASS_ERROR_LIB_NO_CUSTOM_PAYLOAD, 33, "No custom payload") \
  XX(CASS_ERROR_SOURCE_LIB, CASS_ERROR_LIB_EXECUTION_PROFILE_INVALID, 34, "Invalid execution profile specified") \
  XX(CASS_ERROR_SOURCE_LIB, CASS_ERROR_LIB_NO_TRACING_ID, 35, "No tracing ID") \
  XX(CASS_ERROR_SOURCE_SERVER, CASS_ERROR_SERVER_SERVER_ERROR, 0x0000, "Server error") \
  XX(CASS_ERROR_SOURCE_SERVER, CASS_ERROR_SERVER_PROTOCOL_ERROR, 0x000A, "Protocol error") \
  XX(CASS_ERROR_SOURCE_SERVER, CASS_ERROR_SERVER_BAD_CREDENTIALS, 0x0100, "Bad credentials") \
  XX(CASS_ERROR_SOURCE_SERVER, CASS_ERROR_SERVER_UNAVAILABLE, 0x1000, "Unavailable") \
  XX(CASS_ERROR_SOURCE_SERVER, CASS_ERROR_SERVER_OVERLOADED, 0x1001, "Overloaded") \
  XX(CASS_ERROR_SOURCE_SERVER, CASS_ERROR_SERVER_IS_BOOTSTRAPPING, 0x1002, "Is bootstrapping") \
  XX(CASS_ERROR_SOURCE_SERVER, CASS_ERROR_SERVER_TRUNCATE_ERROR, 0x1003, "Truncate error") \
  XX(CASS_ERROR_SOURCE_SERVER, CASS_ERROR_SERVER_WRITE_TIMEOUT, 0x1100, "Write timeout") \
  XX(CASS_ERROR_SOURCE_SERVER, CASS_ERROR_SERVER_READ_TIMEOUT, 0x1200, "Read timeout") \
  XX(CASS_ERROR_SOURCE_SERVER, CASS_ERROR_SERVER_READ_FAILURE, 0x1300, "Read failure") \
  XX(CASS_ERROR_SOURCE_SERVER, CASS_ERROR_SERVER_FUNCTION_FAILURE, 0x1400, "Function failure") \
  XX(CASS_ERROR_SOURCE_SERVER, CASS_ERROR_SERVER_WRITE_FAILURE, 0x1500, "Write failure") \
  XX(CASS_ERROR_SOURCE_SERVER, CASS_ERROR_SERVER_SYNTAX_ERROR, 0x2000, "Syntax error") \
  XX(CASS_ERROR_SOURCE_SERVER, CASS_ERROR_SERVER_UNAUTHORIZED, 0x2100, "Unauthorized") \
  XX(CASS_ERROR_SOURCE_SERVER, CASS_ERROR_SERVER_INVALID_QUERY, 0x2200, "Invalid query") \
  XX(CASS_ERROR_SOURCE_SERVER, CASS_ERROR_SERVER_CONFIG_ERROR, 0x2300, "Configuration error") \
  XX(CASS_ERROR_SOURCE_SERVER, CASS_ERROR_SERVER_ALREADY_EXISTS, 0x2400, "Already exists") \
  XX(CASS_ERROR_SOURCE_SERVER, CASS_ERROR_SERVER_UNPREPARED, 0x2500, "Unprepared") \
  XX(CASS_ERROR_SOURCE_SSL, CASS_ERROR_SSL_INVALID_CERT, 1, "Unable to load certificate") \
  XX(CASS_ERROR_SOURCE_SSL, CASS_ERROR_SSL_INVALID_PRIVATE_KEY, 2, "Unable to load private key") \
  XX(CASS_ERROR_SOURCE_SSL, CASS_ERROR_SSL_NO_PEER_CERT, 3, "No peer certificate")  \
  XX(CASS_ERROR_SOURCE_SSL, CASS_ERROR_SSL_INVALID_PEER_CERT, 4, "Invalid peer certificate") \
  XX(CASS_ERROR_SOURCE_SSL, CASS_ERROR_SSL_IDENTITY_MISMATCH, 5, "Certificate does not match host or IP address") \
  XX(CASS_ERROR_SOURCE_SSL, CASS_ERROR_SSL_PROTOCOL_ERROR, 6, "Protocol error") \
  XX(CASS_ERROR_SOURCE_SSL, CASS_ERROR_SSL_CLOSED, 7, "Connection closed")

/* @cond IGNORE */
#define CASS_ERROR_MAP CASS_ERROR_MAPPING /* Deprecated */
/* @endcond*/

#define CASS_ERROR(source, code) ((source << 24) | code)

typedef enum CassError_ {
  CASS_OK = 0,
#define XX_ERROR(source, name, code, _) name = CASS_ERROR(source, code),
  CASS_ERROR_MAPPING(XX_ERROR)
#undef XX_ERROR
  /* @cond IGNORE */
  CASS_ERROR_LAST_ENTRY
  /* @endcond*/
} CassError;

/**
 * A callback that's notified when the future is set.
 *
 * @param[in] message
 * @param[in] data user defined data provided when the callback
 * was registered.
 *
 * @see cass_future_set_callback()
 */
typedef void (*CassFutureCallback)(CassFuture* future,
                                   void* data);

/**
 * Maximum size of a log message
 */
#define CASS_LOG_MAX_MESSAGE_SIZE 1024

/**
 * A log message.
 */
typedef struct CassLogMessage_ {
  /**
   * The millisecond timestamp (since the Epoch) when the message was logged
   */
  cass_uint64_t time_ms;
  CassLogLevel severity; /**< The severity of the log message */
  const char* file; /**< The file where the message was logged */
  int line; /**< The line in the file where the message was logged */
  const char* function; /**< The function where the message was logged */
  char message[CASS_LOG_MAX_MESSAGE_SIZE]; /**< The message */
} CassLogMessage;

/**
 * A callback that's used to handle logging.
 *
 * @param[in] message
 * @param[in] data user defined data provided when the callback
 * was registered.
 *
 * @see cass_log_set_callback()
 */
typedef void (*CassLogCallback)(const CassLogMessage* message,
                                void* data);

/**
 * A custom malloc function. This function should allocate "size" bytes and
 * return a pointer to that memory
 *
 * @param[in] size The size of the memory to allocate
 *
 * @see CassFreeFunction
 * @see cass_alloc_set_functions()
 */
typedef void* (*CassMallocFunction)(size_t size);

/**
 * A custom realloc function. This function attempts to change the size of the
 * memory pointed to by "ptr". If the memory cannot be resized then new memory
 * should be allocated and contain the contents of the original memory at "ptr".
 *
 * @param[in] ptr A pointer to the original memory. If NULL it should behave the
 * same as "CassMallocFunction"
 * @param[in] size The size of the memory to allocate/resize.
 *
 * @see CassMallocFunction
 * @see CassFreeFunction
 * @see cass_alloc_set_functions()
 */
typedef void* (*CassReallocFunction)(void* ptr, size_t size);

/**
 * A custom free function. This function deallocates the memory pointed to by
 * "ptr" that was previously allocated by a "CassMallocFunction" or
 * "CassReallocFunction" function.
 *
 * @param[in] ptr A pointer to memory that should be deallocated. If NULL then
 * this will perform no operation.
 *
 * @see CassMallocFunction
 * @see CassReallocFunction
 * @see cass_alloc_set_functions()
 */
typedef void (*CassFreeFunction)(void* ptr);

/**
 * An authenticator.
 *
 * @struct CassAuthenticator
 */
typedef struct CassAuthenticator_ CassAuthenticator;

/**
 * A callback used to initiate an authentication exchange.
 *
 * Use cass_authenticator_set_response() to set the response token.
 *
 * Use cass_authenticator_set_error() if an error occurred during
 * initialization.
 *
 * @param[in] auth
 * @param[in] data
 */
typedef void (*CassAuthenticatorInitialCallback)(CassAuthenticator* auth,
                                                 void* data);

/**
 * A callback used when an authentication challenge initiated
 * by the server.
 *
 * Use cass_authenticator_set_response() to set the response token.
 *
 * Use cass_authenticator_set_error() if an error occurred during the
 * challenge.
 *
 * @param[in] auth
 * @param[in] data
 * @param[in] token
 * @param[in] token_size
 */
typedef void (*CassAuthenticatorChallengeCallback)(CassAuthenticator* auth,
                                                   void* data,
                                                   const char* token,
                                                   size_t token_size);
/**
 * A callback used to indicate the success of the authentication
 * exchange.
 *
 * Use cass_authenticator_set_error() if an error occurred while evaluating
 * the success token.
 *
 * @param[in] auth
 * @param[in] data
 * @param[in] token
 * @param[in] token_size
 */
typedef void (*CassAuthenticatorSuccessCallback)(CassAuthenticator* auth,
                                                 void* data,
                                                 const char* token,
                                                 size_t token_size);
/**
 * A callback used to cleanup resources that were acquired during
 * the process of the authentication exchange. This is called after
 * the termination of the exchange regardless of the outcome.
 *
 * @param[in] auth
 * @param[in] data
 */
typedef void (*CassAuthenticatorCleanupCallback)(CassAuthenticator* auth,
                                                 void* data);

/**
 * A callback used to cleanup resources.
 *
 * @param[in] data
 */
typedef void (*CassAuthenticatorDataCleanupCallback)(void* data);

/**
 * Authenticator callbacks
 */
typedef struct CassAuthenticatorCallbacks_ {
  CassAuthenticatorInitialCallback initial_callback;
  CassAuthenticatorChallengeCallback challenge_callback;
  CassAuthenticatorSuccessCallback success_callback;
  CassAuthenticatorCleanupCallback cleanup_callback;
} CassAuthenticatorCallbacks;

typedef enum CassHostListenerEvent_ {
  CASS_HOST_LISTENER_EVENT_UP,
  CASS_HOST_LISTENER_EVENT_DOWN,
  CASS_HOST_LISTENER_EVENT_ADD,
  CASS_HOST_LISTENER_EVENT_REMOVE
} CassHostListenerEvent;

/**
 * A callback used to indicate the host state for a node in the cluster.
 *
 * @param[in] event
 * @param[in] address
 * @param[in] data
 * @see cass_cluster_set_host_listener_callback()
 */
typedef void(*CassHostListenerCallback)(CassHostListenerEvent event,
                                        const CassInet address,
                                        void* data);

/***********************************************************************************
 *
 * Execution Profile
 *
 ***********************************************************************************/

/**
 * An execution profile object provides a mechanism to group together a set of
 * configuration options and reuse them across different statement executions.
 * This feature is useful when dealing with different query workloads.
 *
 * @struct CassExecProfile
 */
typedef struct CassExecProfile_ CassExecProfile;

/**
 * Creates a new execution profile.
 *
 * @public @memberof CassExecProfile
 *
 * @return Returns a execution profile that must be freed.
 *
 * @see cass_execution_profile_free()
 */
CASS_EXPORT CassExecProfile*
cass_execution_profile_new();

/**
 * Frees a execution profile instance.
 *
 * @public @memberof CassExecProfile
 *
 * @param[in] profile
 */
CASS_EXPORT void
cass_execution_profile_free(CassExecProfile* profile);

/**
 * Sets the timeout waiting for a response from a node.
 *
 * <b>Default:</b> Disabled (uses the cluster request timeout)
 *
 * @public @memberof CassExecProfile
 *
 * @param[in] profile
 * @param[in] timeout_ms Request timeout in milliseconds. Use 0 for no timeout
 * or CASS_UINT64_MAX to disable.
 * @return CASS_OK if successful, otherwise an error occurred.
 *
 * @see cass_statement_set_request_timeout()
 */
CASS_EXPORT CassError
cass_execution_profile_set_request_timeout(CassExecProfile* profile,
                                           cass_uint64_t timeout_ms);

/**
 * Sets the consistency level.
 *
 * <b>Default:</b> Disabled (uses the default consistency)
 *
 * @public @memberof CassExecProfile
 *
 * @param[in] profile
 * @param[in] consistency
 * @return CASS_OK if successful, otherwise an error occurred.
 *
 * @see cass_statement_set_consistency()
 */
CASS_EXPORT CassError
cass_execution_profile_set_consistency(CassExecProfile* profile,
                                       CassConsistency consistency);

/**
 * Sets the serial consistency level.
 *
 * <b>Default:</b> Disabled (uses the default serial consistency)
 *
 * @public @memberof CassExecProfile
 *
 * @param[in] profile
 * @param[in] serial_consistency
 * @return CASS_OK if successful, otherwise an error occurred.
 *
 * @see cass_statement_set_serial_consistency()
 */
CASS_EXPORT CassError
cass_execution_profile_set_serial_consistency(CassExecProfile* profile,
                                              CassConsistency serial_consistency);

/**
 * Configures the execution profile to use round-robin load balancing.
 *
 * The driver discovers all nodes in a cluster and cycles through
 * them per request. All are considered 'local'.
 *
 * <b>Note:</b> Profile-based load balancing policy is disabled by default;
 * cluster load balancing policy is used when profile does not contain a policy.
 *
 * @public @memberof CassExecProfile
 *
 * @param[in] profile
 * @return CASS_OK if successful, otherwise an error occurred.
 *
 * @see cass_cluster_set_load_balance_round_robin()
 */
CASS_EXPORT CassError
cass_execution_profile_set_load_balance_round_robin(CassExecProfile* profile);

/**
 * Configures the execution profile to use DC-aware load balancing.
 * For each query, all live nodes in a primary 'local' DC are tried first,
 * followed by any node from other DCs.
 *
 * <b>Note:</b> Profile-based load balancing policy is disabled by default;
 * cluster load balancing policy is used when profile does not contain a policy.
 *
 * @deprecated The remote DC settings for DC-aware are not suitable for most
 * scenarios that require DC failover. There is also unhandled gap between
 * replication factor number of nodes failing and the full cluster failing. Only
 * the remote DC settings are being deprecated.
 *
 * @public @memberof CassExecProfile
 *
 * @param[in] profile
 * @param[in] local_dc The primary data center to try first
 * @param[in] used_hosts_per_remote_dc The number of hosts used in each remote
 * DC if no hosts are available in the local dc (<b>deprecated</b>)
 * @param[in] allow_remote_dcs_for_local_cl Allows remote hosts to be used if no
 * local dc hosts are available and the consistency level is LOCAL_ONE or
 * LOCAL_QUORUM (<b>deprecated</b>)
 * @return CASS_OK if successful, otherwise an error occurred.
 *
 * @see cass_cluster_set_load_balance_dc_aware()
 */
CASS_EXPORT CassError
cass_execution_profile_set_load_balance_dc_aware(CassExecProfile* profile,
                                                 const char* local_dc,
                                                 unsigned used_hosts_per_remote_dc,
                                                 cass_bool_t allow_remote_dcs_for_local_cl);

/**
 * Same as cass_execution_profile_set_load_balance_dc_aware(), but with lengths
 * for string parameters.
 *
 * @deprecated The remote DC settings for DC-aware are not suitable for most
 * scenarios that require DC failover. There is also unhandled gap between
 * replication factor number of nodes failing and the full cluster failing. Only
 * the remote DC settings are being deprecated.
 *
 * @public @memberof CassExecProfile
 *
 * @param[in] profile
 * @param[in] local_dc
 * @param[in] local_dc_length
 * @param[in] used_hosts_per_remote_dc (<b>deprecated</b>)
 * @param[in] allow_remote_dcs_for_local_cl (<b>deprecated</b>)
 * @return same as cass_execution_profile_set_load_balance_dc_aware()
 *
 * @see cass_execution_profile_set_load_balance_dc_aware()
 * @see cass_cluster_set_load_balance_dc_aware_n()
 */
CASS_EXPORT CassError
cass_execution_profile_set_load_balance_dc_aware_n(CassExecProfile* profile,
                                                   const char* local_dc,
                                                   size_t local_dc_length,
                                                   unsigned used_hosts_per_remote_dc,
                                                   cass_bool_t allow_remote_dcs_for_local_cl);

/**
 * Configures the execution profile to use token-aware request routing or not.
 *
 * <b>Important:</b> Token-aware routing depends on keyspace metadata.
 * For this reason enabling token-aware routing will also enable retrieving
 * and updating keyspace schema metadata.
 *
 * <b>Default:</b> cass_true (enabled).
 *
 * This routing policy composes the base routing policy, routing
 * requests first to replicas on nodes considered 'local' by
 * the base load balancing policy.
 *
 * <b>Note:</b> Execution profiles use the cluster-level load balancing policy
 * unless enabled. This setting is not applicable unless a load balancing policy
 * is enabled on the execution profile.
 *
 * @public @memberof CassExecProfile
 *
 * @param[in] profile
 * @param[in] enabled
 * @return CASS_OK if successful, otherwise an error occurred.
 *
 * @see cass_cluster_set_token_aware_routing()
 */
CASS_EXPORT CassError
cass_execution_profile_set_token_aware_routing(CassExecProfile* profile,
                                               cass_bool_t enabled);

/**
 * Configures the execution profile's token-aware routing to randomly shuffle
 * replicas. This can reduce the effectiveness of server-side caching, but it
 * can better distribute load over replicas for a given partition key.
 *
 * <b>Note:</b> Token-aware routing must be enabled and a load balancing policy
 * must be enabled on the execution profile for the setting to be applicable.
 *
 * <b>Default:</b> cass_true (enabled).
 *
 * @public @memberof CassExecProfile
 *
 * @param[in] profile
 * @param[in] enabled
 * @return CASS_OK if successful, otherwise an error occurred.
 *
 * @see cass_cluster_set_token_aware_routing_shuffle_replicas()
 */
CASS_EXPORT CassError
cass_execution_profile_set_token_aware_routing_shuffle_replicas(CassExecProfile* profile,
                                                                cass_bool_t enabled);

/**
 * Configures the execution profile to use latency-aware request routing or not.
 *
 * <b>Note:</b> Execution profiles use the cluster-level load balancing policy
 * unless enabled. This setting is not applicable unless a load balancing policy
 * is enabled on the execution profile.
 *
 * <b>Default:</b> cass_false (disabled).
 *
 * This routing policy is a top-level routing policy. It uses the
 * base routing policy to determine locality (dc-aware) and/or
 * placement (token-aware) before considering the latency.
 *
 * @public @memberof CassExecProfile
 *
 * @param[in] profile
 * @param[in] enabled
 * @return CASS_OK if successful, otherwise an error occurred.
 *
 * @see cass_cluster_set_latency_aware_routing()
 */
CASS_EXPORT CassError
cass_execution_profile_set_latency_aware_routing(CassExecProfile* profile,
                                                 cass_bool_t enabled);

/**
 * Configures the execution profile's settings for latency-aware request
 * routing.
 *
 * <b>Note:</b> Execution profiles use the cluster-level load balancing policy
 * unless enabled. This setting is not applicable unless a load balancing policy
 * is enabled on the execution profile.
 *
 * <b>Defaults:</b>
 *
 * <ul>
 *   <li>exclusion_threshold: 2.0</li>
 *   <li>scale_ms: 100 milliseconds</li>
 *   <li>retry_period_ms: 10,000 milliseconds (10 seconds)</li>
 *   <li>update_rate_ms: 100 milliseconds</li>
 *   <li>min_measured: 50</li>
 * </ul>
 *
 * @public @memberof CassExecProfile
 *
 * @param[in] profile
 * @param[in] exclusion_threshold Controls how much worse the latency must be
 * compared to the average latency of the best performing node before it
 * penalized.
 * @param[in] scale_ms Controls the weight given to older latencies when
 * calculating the average latency of a node. A bigger scale will give more
 * weight to older latency measurements.
 * @param[in] retry_period_ms The amount of time a node is penalized by the
 * policy before being given a second chance when the current average latency
 * exceeds the calculated threshold
 * (exclusion_threshold * best_average_latency).
 * @param[in] update_rate_ms The rate at  which the best average latency is
 * recomputed.
 * @param[in] min_measured The minimum number of measurements per-host required
 * to be considered by the policy.
 * @return CASS_OK if successful, otherwise an error occurred.
 *
 * @see cass_cluster_set_latency_aware_routing_settings()
 */
CASS_EXPORT CassError
cass_execution_profile_set_latency_aware_routing_settings(CassExecProfile* profile,
                                                          cass_double_t exclusion_threshold,
                                                          cass_uint64_t scale_ms,
                                                          cass_uint64_t retry_period_ms,
                                                          cass_uint64_t update_rate_ms,
                                                          cass_uint64_t min_measured);

/**
 * Sets/Appends whitelist hosts for the execution profile. The first call sets
 * the whitelist hosts and any subsequent calls appends additional hosts.
 * Passing an empty string will clear and disable the whitelist. White space is
 * striped from the hosts.
 *
 * This policy filters requests to all other policies, only allowing requests
 * to the hosts contained in the whitelist. Any host not in the whitelist will
 * be ignored and a connection will not be established. This policy is useful
 * for ensuring that the driver will only connect to a predefined set of hosts.
 *
 * Examples: "127.0.0.1" "127.0.0.1,127.0.0.2"
 *
 * <b>Note:</b> Execution profiles use the cluster-level load balancing policy
 * unless enabled. This setting is not applicable unless a load balancing policy
 * is enabled on the execution profile.
 *
 * @public @memberof CassExecProfile
 *
 * @param[in] profile
 * @param[in] hosts A comma delimited list of addresses. An empty string will
 * clear the whitelist hosts. The string is copied into the cluster
 * configuration; the memory pointed to by this parameter can be freed after
 * this call.
 * @return CASS_OK if successful, otherwise an error occurred.
 *
 * @see cass_cluster_set_whitelist_filtering()
 */
CASS_EXPORT CassError
cass_execution_profile_set_whitelist_filtering(CassExecProfile* profile,
                                               const char* hosts);

/**
 * Same as cass_execution_profile_set_whitelist_filtering(), but with lengths
 * for string parameters.
 *
 * @public @memberof CassExecProfile
 *
 * @param[in] profile
 * @param[in] hosts
 * @param[in] hosts_length
 * @return same as cass_execution_profile_set_whitelist_filtering()
 *
 * @see cass_execution_profile_set_whitelist_filtering()
 * @see cass_cluster_set_whitelist_filtering()
 */
CASS_EXPORT CassError
cass_execution_profile_set_whitelist_filtering_n(CassExecProfile* profile,
                                                 const char* hosts,
                                                 size_t hosts_length);

/**
 * Sets/Appends blacklist hosts for the execution profile. The first call sets
 * the blacklist hosts and any subsequent calls appends additional hosts.
 * Passing an empty string will clear and disable the blacklist. White space is
 * striped from the hosts.
 *
 * This policy filters requests to all other policies, only allowing requests
 * to the hosts not contained in the blacklist. Any host in the blacklist will
 * be ignored and a connection will not be established. This policy is useful
 * for ensuring that the driver will not connect to a predefined set of hosts.
 *
 * Examples: "127.0.0.1" "127.0.0.1,127.0.0.2"
 *
 * <b>Note:</b> Execution profiles use the cluster-level load balancing policy
 * unless enabled. This setting is not applicable unless a load balancing policy
 * is enabled on the execution profile.
 *
 * @public @memberof CassExecProfile
 *
 * @param[in] profile
 * @param[in] hosts A comma delimited list of addresses. An empty string will
 * clear the blacklist hosts. The string is copied into the cluster
 * configuration; the memory pointed to by this parameter can be freed after
 * this call.
 * @return CASS_OK if successful, otherwise an error occurred.
 *
 * @see cass_cluster_set_blacklist_filtering()
 */
CASS_EXPORT CassError
cass_execution_profile_set_blacklist_filtering(CassExecProfile* profile,
                                               const char* hosts);

/**
 * Same as cass_execution_profile_set_blacklist_filtering(), but with lengths
 * for string parameters.
 *
 * @public @memberof CassExecProfile
 *
 * @param[in] profile
 * @param[in] hosts
 * @param[in] hosts_length
 * @return same as cass_execution_profile_set_blacklist_filtering_hosts()
 *
 * @see cass_execution_profile_set_blacklist_filtering()
 * @see cass_cluster_set_blacklist_filtering()
 */
CASS_EXPORT CassError
cass_execution_profile_set_blacklist_filtering_n(CassExecProfile* profile,
                                                 const char* hosts,
                                                 size_t hosts_length);

/**
 * Same as cass_execution_profile_set_whitelist_filtering(), but whitelist all
 * hosts of a dc.
 *
 * Examples: "dc1", "dc1,dc2"
 *
 * @public @memberof CassExecProfile
 *
 * @param[in] profile
 * @param[in] dcs A comma delimited list of dcs. An empty string will clear the
 * whitelist dcs. The string is copied into the cluster configuration; the
 * memory pointed to by this parameter can be freed after this call.
 * @return CASS_OK if successful, otherwise an error occurred.
 *
 * @see cass_cluster_set_whitelist_dc_filtering()
 */
CASS_EXPORT CassError
cass_execution_profile_set_whitelist_dc_filtering(CassExecProfile* profile,
                                                  const char* dcs);

/**
 * Same as cass_execution_profile_set_whitelist_dc_filtering(), but with lengths
 * for string parameters.
 *
 * @public @memberof CassExecProfile
 *
 * @param[in] profile
 * @param[in] dcs
 * @param[in] dcs_length
 * @return same as cass_execution_profile_set_whitelist_dc_filtering()
 *
 * @see cass_execution_profile_set_whitelist_dc_filtering()
 * @see cass_cluster_set_whitelist_dc_filtering()
 */
CASS_EXPORT CassError
cass_execution_profile_set_whitelist_dc_filtering_n(CassExecProfile* profile,
                                                    const char* dcs,
                                                    size_t dcs_length);

/**
 * Same as cass_execution_profile_set_blacklist_filtering(), but blacklist all
 * hosts of a dc.
 *
 * Examples: "dc1", "dc1,dc2"
 *
 * @public @memberof CassExecProfile
 *
 * @param[in] profile
 * @param[in] dcs A comma delimited list of dcs. An empty string will clear the
 * blacklist dcs. The string is copied into the cluster configuration; the
 * memory pointed to by this parameter can be freed after this call.
 * @return CASS_OK if successful, otherwise an error occurred.
 *
 * @see cass_execution_profile_set_blacklist_filtering()
 * @see cass_cluster_set_blacklist_dc_filtering()
 */
CASS_EXPORT CassError
cass_execution_profile_set_blacklist_dc_filtering(CassExecProfile* profile,
                                                  const char* dcs);

/**
 * Same as cass_execution_profile_set_blacklist_dc_filtering(), but with lengths
 * for string parameters.
 *
 * @public @memberof CassExecProfile
 *
 * @param[in] profile
 * @param[in] dcs
 * @param[in] dcs_length
 * @return same as cass_execution_profile_set_blacklist_dc_filtering()
 *
 * @see cass_execution_profile_set_blacklist_dc_filtering()
 * @see cass_cluster_set_blacklist_dc_filtering()
 */
CASS_EXPORT CassError
cass_execution_profile_set_blacklist_dc_filtering_n(CassExecProfile* profile,
                                                    const char* dcs,
                                                    size_t dcs_length);

/**
 * Sets the execution profile's retry policy.
 *
 * <b>Note:</b> Profile-based retry policy is disabled by default; cluster retry
 * policy is used when profile does not contain a policy unless the retry policy
 * was explicitly set on the batch/statement request.
 *
 * @public @memberof CassExecProfile
 *
 * @param[in] profile
 * @param[in] retry_policy NULL will clear retry policy from execution profile
 * @return CASS_OK if successful, otherwise an error occurred.
 *
 * @see cass_cluster_set_retry_policy()
 */
CASS_EXPORT CassError
cass_execution_profile_set_retry_policy(CassExecProfile* profile,
                                        CassRetryPolicy* retry_policy);

/**
 * Enable constant speculative executions with the supplied settings for the
 * execution profile.
 *
 * <b>Note:</b> Profile-based speculative execution policy is disabled by
 * default; cluster speculative execution policy is used when profile does not
 * contain a policy.
 *
 * @public @memberof CassExecProfile
 *
 * @param[in] profile
 * @param[in] constant_delay_ms
 * @param[in] max_speculative_executions
 * @return CASS_OK if successful, otherwise an error occurred
 *
 * @see cass_cluster_set_constant_speculative_execution_policy()
 */
CASS_EXPORT CassError
cass_execution_profile_set_constant_speculative_execution_policy(CassExecProfile* profile,
                                                                 cass_int64_t constant_delay_ms,
                                                                 int max_speculative_executions);

/**
 * Disable speculative executions for the execution profile.
 *
 * <b>Note:</b> Profile-based speculative execution policy is disabled by
 * default; cluster speculative execution policy is used when profile does not
 * contain a policy.
 *
 * @public @memberof CassExecProfile
 *
 * @param[in] profile
 * @return CASS_OK if successful, otherwise an error occurred
 *
 * @see cass_cluster_set_no_speculative_execution_policy()
 */
CASS_EXPORT CassError
cass_execution_profile_set_no_speculative_execution_policy(CassExecProfile* profile);

/***********************************************************************************
 *
 * Cluster
 *
 ***********************************************************************************/

/**
 * Creates a new cluster.
 *
 * @public @memberof CassCluster
 *
 * @return Returns a cluster that must be freed.
 *
 * @see cass_cluster_free()
 */
CASS_EXPORT CassCluster*
cass_cluster_new();

/**
 * Frees a cluster instance.
 *
 * @public @memberof CassCluster
 *
 * @param[in] cluster
 */
CASS_EXPORT void
cass_cluster_free(CassCluster* cluster);

/**
 * Sets/Appends contact points. This *MUST* be set. The first call sets
 * the contact points and any subsequent calls appends additional contact
 * points. Passing an empty string will clear the contact points. White space
 * is striped from the contact points.
 *
 * Examples: "127.0.0.1" "127.0.0.1,127.0.0.2", "server1.domain.com"
 *
 * @public @memberof CassCluster
 *
 * @param[in] cluster
 * @param[in] contact_points A comma delimited list of addresses or
 * names. An empty string will clear the contact points.
 * The string is copied into the cluster configuration; the memory pointed
 * to by this parameter can be freed after this call.
 * @return CASS_OK if successful, otherwise an error occurred.
 */
CASS_EXPORT CassError
cass_cluster_set_contact_points(CassCluster* cluster,
                                const char* contact_points);

/**
 * Same as cass_cluster_set_contact_points(), but with lengths for string
 * parameters.
 *
 * @public @memberof CassCluster
 *
 * @param[in] cluster
 * @param[in] contact_points
 * @param[in] contact_points_length
 * @return same as cass_cluster_set_contact_points()
 *
 * @see cass_cluster_set_contact_points()
 */
CASS_EXPORT CassError
cass_cluster_set_contact_points_n(CassCluster* cluster,
                                  const char* contact_points,
                                  size_t contact_points_length);

/**
 * Sets the port.
 *
 * <b>Default:</b> 9042
 *
 * @public @memberof CassCluster
 *
 * @param[in] cluster
 * @param[in] port
 * @return CASS_OK if successful, otherwise an error occurred.
 */
CASS_EXPORT CassError
cass_cluster_set_port(CassCluster* cluster,
                      int port);

/**
 * Sets the local address to bind when connecting to the cluster,
 * if desired.
 *
 * @public @memberof CassCluster
 *
 * @param[in] cluster
 * @param[in] name IP address to bind, or empty string for no binding.
 * Only numeric addresses are supported; no resolution is done.
 * @return CASS_OK if successful, otherwise an error occurred.
 */
CASS_EXPORT CassError
cass_cluster_set_local_address(CassCluster* cluster,
                               const char* name);

/**
 * Same as cass_cluster_set_local_address(), but with lengths for string
 * parameters.
 *
 * @public @memberof CassCluster
 *
 * @param[in] cluster
 * @param[in] name
 * @param[in] name_length
 * @return same as cass_cluster_set_local_address()
 *
 * @see cass_cluster_set_local_address()
 */
CASS_EXPORT CassError
cass_cluster_set_local_address_n(CassCluster* cluster,
                                 const char* name,
                                 size_t name_length);

/**
 * Sets the SSL context and enables SSL.
 *
 * @public @memberof CassCluster
 *
 * @param[in] cluster
 * @param[in] ssl
 *
 * @see cass_ssl_new()
 */
CASS_EXPORT void
cass_cluster_set_ssl(CassCluster* cluster,
                     CassSsl* ssl);

/**
 * Sets custom authenticator
 *
 * @public @memberof CassCluster
 *
 * @param[in] cluster
 * @param[in] exchange_callbacks
 * @param[in] cleanup_callback
 * @param[in] data
 * @return CASS_OK if successful, otherwise an error occurred.
 */
CASS_EXPORT CassError
cass_cluster_set_authenticator_callbacks(CassCluster* cluster,
                                         const CassAuthenticatorCallbacks* exchange_callbacks,
                                         CassAuthenticatorDataCleanupCallback cleanup_callback,
                                         void* data);

/**
 * Sets the protocol version. The driver will automatically downgrade to the lowest
 * supported protocol version.
 *
 * <b>Default:</b> CASS_PROTOCOL_VERSION_V4 or CASS_PROTOCOL_VERSION_DSEV1 when
 * using the DSE driver with DataStax Enterprise.
 *
 * @public @memberof CassCluster
 *
 * @param[in] cluster
 * @param[in] protocol_version
 * @return CASS_OK if successful, otherwise an error occurred.
 *
 * @see cass_cluster_set_use_beta_protocol_version()
 */
CASS_EXPORT CassError
cass_cluster_set_protocol_version(CassCluster* cluster,
                                  int protocol_version);

/**
 * Use the newest beta protocol version. This currently enables the use of
 * protocol version v5 (CASS_PROTOCOL_VERSION_V5) or DSEv2 (CASS_PROTOCOL_VERSION_DSEV2)
 * when using the DSE driver with DataStax Enterprise.
 *
 * <b>Default:</b> cass_false
 *
 * @public @memberof CassCluster
 *
 * @param[in] cluster
 * @param[in] enable if false the highest non-beta protocol version will be used
 * @return CASS_OK if successful, otherwise an error occurred.
 */
CASS_EXPORT CassError
cass_cluster_set_use_beta_protocol_version(CassCluster* cluster,
                                           cass_bool_t enable);

/**
 * Sets default consistency level of statement.
 *
 * <b>Default:</b> CASS_CONSISTENCY_LOCAL_ONE
 *
 * @public @memberof CassCluster
 *
 * @param[in] cluster
 * @param[in] consistency
 * @return CASS_OK if successful, otherwise an error occurred.
 */
CASS_EXPORT CassError
cass_cluster_set_consistency(CassCluster* cluster,
                             CassConsistency consistency);

/**
 * Sets default serial consistency level of statement.
 *
 * <b>Default:</b> CASS_CONSISTENCY_ANY
 *
 * @public @memberof CassCluster
 *
 * @param[in] cluster
 * @param[in] consistency
 * @return CASS_OK if successful, otherwise an error occurred.
 */
CASS_EXPORT CassError
cass_cluster_set_serial_consistency(CassCluster* cluster,
                                    CassConsistency consistency);

/**
 * Sets the number of IO threads. This is the number of threads
 * that will handle query requests.
 *
 * <b>Default:</b> 1
 *
 * @public @memberof CassCluster
 *
 * @param[in] cluster
 * @param[in] num_threads
 * @return CASS_OK if successful, otherwise an error occurred.
 */
CASS_EXPORT CassError
cass_cluster_set_num_threads_io(CassCluster* cluster,
                                unsigned num_threads);

/**
 * Sets the size of the fixed size queue that stores
 * pending requests.
 *
 * <b>Default:</b> 8192
 *
 * @public @memberof CassCluster
 *
 * @param[in] cluster
 * @param[in] queue_size
 * @return CASS_OK if successful, otherwise an error occurred.
 */
CASS_EXPORT CassError
cass_cluster_set_queue_size_io(CassCluster* cluster,
                               unsigned queue_size);

/**
 * Sets the size of the fixed size queue that stores
 * events.
 *
 * <b>Default:</b> 8192
 *
 * @public @memberof CassCluster
 *
 * @deprecated This is no longer useful and does nothing. Expect this to be
 * removed in a future release.
 *
 * @param[in] cluster
 * @param[in] queue_size
 * @return CASS_OK if successful, otherwise an error occurred.
 */
CASS_EXPORT CASS_DEPRECATED(CassError
cass_cluster_set_queue_size_event(CassCluster* cluster,
                                  unsigned queue_size));

/**
 * Sets the number of connections made to each server in each
 * IO thread.
 *
 * <b>Default:</b> 1
 *
 * @public @memberof CassCluster
 *
 * @param[in] cluster
 * @param[in] num_connections
 * @return CASS_OK if successful, otherwise an error occurred.
 */
CASS_EXPORT CassError
cass_cluster_set_core_connections_per_host(CassCluster* cluster,
                                           unsigned num_connections);

/**
 * Sets the maximum number of connections made to each server in each
 * IO thread.
 *
 * <b>Default:</b> 2
 *
 * @public @memberof CassCluster
 *
 * @deprecated This is no longer useful and does nothing. Expect this to be
 * removed in a future release.
 *
 * @param[in] cluster
 * @param[in] num_connections
 * @return CASS_OK if successful, otherwise an error occurred.
 */
CASS_EXPORT CASS_DEPRECATED(CassError
cass_cluster_set_max_connections_per_host(CassCluster* cluster,
                                          unsigned num_connections));

/**
 * Sets the amount of time to wait before attempting to reconnect.
 *
 * @public @memberof CassCluster
 *
 * @deprecated This is being replaced with cass_cluster_set_constant_reconnect().
 * Expect this to be removed in a future release.
 *
 * @param[in] cluster
 * @param[in] wait_time
 */
CASS_EXPORT CASS_DEPRECATED(void
cass_cluster_set_reconnect_wait_time(CassCluster* cluster,
                                     unsigned wait_time));

/**
 * Configures the cluster to use a reconnection policy that waits a constant
 * time between each reconnection attempt.
 *
 * @public @memberof CassCluster
 *
 * @param[in] cluster
 * @param[in] delay_ms Time in milliseconds to delay attempting a reconnection;
 * 0 to perform a reconnection immediately.
 */
CASS_EXPORT void
cass_cluster_set_constant_reconnect(CassCluster* cluster,
                                    cass_uint64_t delay_ms);

/**
 * Configures the cluster to use a reconnection policy that waits exponentially
 * longer between each reconnection attempt; however will maintain a constant
 * delay once the maximum delay is reached.
 *
 * <b>Default:</b>
 * <ul>
 *   <li>2000 milliseconds base delay</li>
 *   <li>60000 milliseconds max delay</li>
 * </ul>
 *
 * <p>
 *   <b>Note:</b> A random amount of jitter (+/- 15%) will be added to the pure
 *   exponential delay value. This helps to prevent situations where multiple
 *   connections are in the reconnection process at exactly the same time. The
 *   jitter will never cause the delay to be less than the base delay, or more
 *   than the max delay.
 * </p>
 *
 * @public @memberof CassCluster
 *
 * @param[in] cluster
 * @param[in] base_delay_ms The base delay (in milliseconds) to use for
 * scheduling reconnection attempts.
 * @param[in] max_delay_ms The maximum delay to wait between two reconnection
 * attempts.
 * @return CASS_OK if successful, otherwise error occurred.
 */
CASS_EXPORT CassError
cass_cluster_set_exponential_reconnect(CassCluster* cluster,
                                       cass_uint64_t base_delay_ms,
                                       cass_uint64_t max_delay_ms);

/**
 * Sets the amount of time, in microseconds, to wait for new requests to
 * coalesce into a single system call. This should be set to a value around
 * the latency SLA of your application's requests while also considering the
 * request's roundtrip time. Larger values should be used for throughput
 * bound workloads and lower values should be used for latency bound
 * workloads.
 *
 * <b>Default:</b> 200 us
 *
 * @public @memberof CassCluster
 *
 * @param[in] cluster
 * @param[in] delay_us
 * @return CASS_OK if successful, otherwise an error occurred.
 */
CASS_EXPORT CassError
cass_cluster_set_coalesce_delay(CassCluster* cluster,
                                cass_int64_t delay_us);

/**
 * Sets the ratio of time spent processing new requests versus handling the I/O
 * and processing of outstanding requests. The range of this setting is 1 to 100,
 * where larger values allocate more time to processing new requests and smaller
 * values allocate more time to processing outstanding requests.
 *
 * <b>Default:</b> 50
 *
 * @public @memberof CassCluster
 *
 * @param[in] cluster
 * @param[in] ratio
 * @return CASS_OK if successful, otherwise an error occurred.
 */
CASS_EXPORT CassError
cass_cluster_set_new_request_ratio(CassCluster* cluster,
                                   cass_int32_t ratio);

/**
 * Sets the maximum number of connections that will be created concurrently.
 * Connections are created when the current connections are unable to keep up with
 * request throughput.
 *
 * <b>Default:</b> 1
 *
 * @public @memberof CassCluster
 *
 * @deprecated This is no longer useful and does nothing. Expect this to be
 * removed in a future release.
 *
 * @param[in] cluster
 * @param[in] num_connections
 * @return CASS_OK if successful, otherwise an error occurred.
 */
CASS_EXPORT CASS_DEPRECATED(CassError
cass_cluster_set_max_concurrent_creation(CassCluster* cluster,
                                         unsigned num_connections));

/**
 * Sets the threshold for the maximum number of concurrent requests in-flight
 * on a connection before creating a new connection. The number of new connections
 * created will not exceed max_connections_per_host.
 *
 * <b>Default:</b> 100
 *
 * @public @memberof CassCluster
 *
 * @deprecated This is no longer useful and does nothing. Expect this to be
 * removed in a future release.
 *
 * @param[in] cluster
 * @param[in] num_requests
 * @return CASS_OK if successful, otherwise an error occurred.
 */
CASS_EXPORT CASS_DEPRECATED(CassError
cass_cluster_set_max_concurrent_requests_threshold(CassCluster* cluster,
                                                   unsigned num_requests));

/**
 * Sets the maximum number of requests processed by an IO worker
 * per flush.
 *
 * <b>Default:</b> 128
 *
 * @public @memberof CassCluster
 *
 * @deprecated This is no longer useful and does nothing. Expect this to be
 * removed in a future release.
 *
 * @param[in] cluster
 * @param[in] num_requests
 * @return CASS_OK if successful, otherwise an error occurred.
 */
CASS_EXPORT CASS_DEPRECATED(CassError
cass_cluster_set_max_requests_per_flush(CassCluster* cluster,
                                        unsigned num_requests));

/**
 * Sets the high water mark for the number of bytes outstanding
 * on a connection. Disables writes to a connection if the number
 * of bytes queued exceed this value.
 *
 * <b>Default:</b> 64 KB
 *
 * @public @memberof CassCluster
 *
 * @deprecated This is no longer useful and does nothing. Expect this to be
 * removed in a future release.
 *
 * @param[in] cluster
 * @param[in] num_bytes
 * @return CASS_OK if successful, otherwise an error occurred.
 */
CASS_EXPORT CASS_DEPRECATED(CassError
cass_cluster_set_write_bytes_high_water_mark(CassCluster* cluster,
                                             unsigned num_bytes));

/**
 * Sets the low water mark for number of bytes outstanding on a
 * connection. After exceeding high water mark bytes, writes will
 * only resume once the number of bytes fall below this value.
 *
 * <b>Default:</b> 32 KB
 *
 * @public @memberof CassCluster
 *
 * @deprecated This is no longer useful and does nothing. Expect this to be
 * removed in a future release.
 *
 * @param[in] cluster
 * @param[in] num_bytes
 * @return CASS_OK if successful, otherwise an error occurred.
 */
CASS_EXPORT CASS_DEPRECATED(CassError
cass_cluster_set_write_bytes_low_water_mark(CassCluster* cluster,
                                            unsigned num_bytes));

/**
 * Sets the high water mark for the number of requests queued waiting
 * for a connection in a connection pool. Disables writes to a
 * host on an IO worker if the number of requests queued exceed this
 * value.
 *
 * <b>Default:</b> 256
 *
 * @public @memberof CassCluster
 *
 * @deprecated This is no longer useful and does nothing. Expect this to be
 * removed in a future release.
 *
 * @param[in] cluster
 * @param[in] num_requests
 * @return CASS_OK if successful, otherwise an error occurred.
 */
CASS_EXPORT CASS_DEPRECATED(CassError
cass_cluster_set_pending_requests_high_water_mark(CassCluster* cluster,
                                                  unsigned num_requests));

/**
 * Sets the low water mark for the number of requests queued waiting
 * for a connection in a connection pool. After exceeding high water mark
 * requests, writes to a host will only resume once the number of requests
 * fall below this value.
 *
 * <b>Default:</b> 128
 *
 * @public @memberof CassCluster
 *
 * @deprecated This is no longer useful and does nothing. Expect this to be
 * removed in a future release.
 *
 * @param[in] cluster
 * @param[in] num_requests
 * @return CASS_OK if successful, otherwise an error occurred.
 */
CASS_EXPORT CASS_DEPRECATED(CassError
cass_cluster_set_pending_requests_low_water_mark(CassCluster* cluster,
                                                 unsigned num_requests));

/**
 * Sets the timeout for connecting to a node.
 *
 * <b>Default:</b> 5000 milliseconds
 *
 * @public @memberof CassCluster
 *
 * @param[in] cluster
 * @param[in] timeout_ms Connect timeout in milliseconds
 */
CASS_EXPORT void
cass_cluster_set_connect_timeout(CassCluster* cluster,
                                 unsigned timeout_ms);

/**
 * Sets the timeout for waiting for a response from a node.
 *
 * <b>Default:</b> 12000 milliseconds
 *
 * @public @memberof CassCluster
 *
 * @param[in] cluster
 * @param[in] timeout_ms Request timeout in milliseconds. Use 0 for no timeout.
 */
CASS_EXPORT void
cass_cluster_set_request_timeout(CassCluster* cluster,
                                 unsigned timeout_ms);

/**
 * Sets the timeout for waiting for DNS name resolution.
 *
 * <b>Default:</b> 2000 milliseconds
 *
 * @public @memberof CassCluster
 *
 * @param[in] cluster
 * @param[in] timeout_ms Request timeout in milliseconds
 */
CASS_EXPORT void
cass_cluster_set_resolve_timeout(CassCluster* cluster,
                                 unsigned timeout_ms);

/**
 * Sets the maximum time to wait for schema agreement after a schema change
 * is made (e.g. creating, altering, dropping a table/keyspace/view/index etc).
 *
 * <b>Default:</b> 10000 milliseconds
 *
 * @public @memberof CassCluster
 *
 * @param[in] cluster
 * @param[in] wait_time_ms Wait time in milliseconds
 */
CASS_EXPORT void
cass_cluster_set_max_schema_wait_time(CassCluster* cluster,
                                      unsigned wait_time_ms);


/**
 * Sets the maximum time to wait for tracing data to become available.
 *
 * <b>Default:</b> 15 milliseconds
 *
 * @param[in] cluster
 * @param[in] max_wait_time_ms
 */
CASS_EXPORT void
cass_cluster_set_tracing_max_wait_time(CassCluster* cluster,
                                       unsigned max_wait_time_ms);

/**
 * Sets the amount of time to wait between attempts to check to see if tracing is
 * available.
 *
 * <b>Default:</b> 3 milliseconds
 *
 * @param[in] cluster
 * @param[in] retry_wait_time_ms
 */
CASS_EXPORT void
cass_cluster_set_tracing_retry_wait_time(CassCluster* cluster,
                                         unsigned retry_wait_time_ms);

/**
 * Sets the consistency level to use for checking to see if tracing data is
 * available.
 *
 * <b>Default:</b> CASS_CONSISTENCY_ONE
 *
 * @param[in] cluster
 * @param[in] consistency
 */
CASS_EXPORT void
cass_cluster_set_tracing_consistency(CassCluster* cluster,
                                     CassConsistency consistency);


/**
 * Sets credentials for plain text authentication.
 *
 * @public @memberof CassCluster
 *
 * @param[in] cluster
 * @param[in] username
 * @param[in] password
 */
CASS_EXPORT void
cass_cluster_set_credentials(CassCluster* cluster,
                             const char* username,
                             const char* password);

/**
 * Same as cass_cluster_set_credentials(), but with lengths for string
 * parameters.
 *
 * @public @memberof CassCluster
 *
 * @param[in] cluster
 * @param[in] username
 * @param[in] username_length
 * @param[in] password
 * @param[in] password_length
 * @return same as cass_cluster_set_credentials()
 *
 * @see cass_cluster_set_credentials();
 */
CASS_EXPORT void
cass_cluster_set_credentials_n(CassCluster* cluster,
                               const char* username,
                               size_t username_length,
                               const char* password,
                               size_t password_length);

/**
 * Configures the cluster to use round-robin load balancing.
 *
 * The driver discovers all nodes in a cluster and cycles through
 * them per request. All are considered 'local'.
 *
 * @public @memberof CassCluster
 *
 * @param[in] cluster
 */
CASS_EXPORT void
cass_cluster_set_load_balance_round_robin(CassCluster* cluster);

/**
 * Configures the cluster to use DC-aware load balancing.
 * For each query, all live nodes in a primary 'local' DC are tried first,
 * followed by any node from other DCs.
 *
 * <b>Note:</b> This is the default, and does not need to be called unless
 * switching an existing from another policy or changing settings.
 * Without further configuration, a default local_dc is chosen from the
 * first connected contact point, and no remote hosts are considered in
 * query plans. If relying on this mechanism, be sure to use only contact
 * points from the local DC.
 *
 * @deprecated The remote DC settings for DC-aware are not suitable for most
 * scenarios that require DC failover. There is also unhandled gap between
 * replication factor number of nodes failing and the full cluster failing. Only
 * the remote DC settings are being deprecated.
 *
 * @public @memberof CassCluster
 *
 * @param[in] cluster
 * @param[in] local_dc The primary data center to try first
 * @param[in] used_hosts_per_remote_dc The number of hosts used in each remote
 * DC if no hosts are available in the local dc (<b>deprecated</b>)
 * @param[in] allow_remote_dcs_for_local_cl Allows remote hosts to be used if no
 * local dc hosts are available and the consistency level is LOCAL_ONE or
 * LOCAL_QUORUM (<b>deprecated</b>)
 * @return CASS_OK if successful, otherwise an error occurred
 */
CASS_EXPORT CassError
cass_cluster_set_load_balance_dc_aware(CassCluster* cluster,
                                       const char* local_dc,
                                       unsigned used_hosts_per_remote_dc,
                                       cass_bool_t allow_remote_dcs_for_local_cl);


/**
 * Same as cass_cluster_set_load_balance_dc_aware(), but with lengths for string
 * parameters.
 *
 * @deprecated The remote DC settings for DC-aware are not suitable for most
 * scenarios that require DC failover. There is also unhandled gap between
 * replication factor number of nodes failing and the full cluster failing. Only
 * the remote DC settings are being deprecated.
 *
 * @public @memberof CassCluster
 *
 * @param[in] cluster
 * @param[in] local_dc
 * @param[in] local_dc_length
 * @param[in] used_hosts_per_remote_dc (<b>deprecated</b>)
 * @param[in] allow_remote_dcs_for_local_cl (<b>deprecated</b>)
 * @return same as cass_cluster_set_load_balance_dc_aware()
 *
 * @see cass_cluster_set_load_balance_dc_aware()
 */
CASS_EXPORT CassError
cass_cluster_set_load_balance_dc_aware_n(CassCluster* cluster,
                                         const char* local_dc,
                                         size_t local_dc_length,
                                         unsigned used_hosts_per_remote_dc,
                                         cass_bool_t allow_remote_dcs_for_local_cl);

/**
 * Configures the cluster to use token-aware request routing or not.
 *
 * <b>Important:</b> Token-aware routing depends on keyspace metadata.
 * For this reason enabling token-aware routing will also enable retrieving
 * and updating keyspace schema metadata.
 *
 * <b>Default:</b> cass_true (enabled).
 *
 * This routing policy composes the base routing policy, routing
 * requests first to replicas on nodes considered 'local' by
 * the base load balancing policy.
 *
 * @public @memberof CassCluster
 *
 * @param[in] cluster
 * @param[in] enabled
 */
CASS_EXPORT void
cass_cluster_set_token_aware_routing(CassCluster* cluster,
                                     cass_bool_t enabled);


/**
 * Configures token-aware routing to randomly shuffle replicas. This can reduce
 * the effectiveness of server-side caching, but it can better distribute load over
 * replicas for a given partition key.
 *
 * <b>Note:</b> Token-aware routing must be enabled for the setting to
 * be applicable.
 *
 * <b>Default:</b> cass_true (enabled).
 *
 * @public @memberof CassCluster
 *
 * @param[in] cluster
 * @param[in] enabled
 */
CASS_EXPORT void
cass_cluster_set_token_aware_routing_shuffle_replicas(CassCluster* cluster,
                                                      cass_bool_t enabled);

/**
 * Configures the cluster to use latency-aware request routing or not.
 *
 * <b>Default:</b> cass_false (disabled).
 *
 * This routing policy is a top-level routing policy. It uses the
 * base routing policy to determine locality (dc-aware) and/or
 * placement (token-aware) before considering the latency.
 *
 * @public @memberof CassCluster
 *
 * @param[in] cluster
 * @param[in] enabled
 */
CASS_EXPORT void
cass_cluster_set_latency_aware_routing(CassCluster* cluster,
                                       cass_bool_t enabled);

/**
 * Configures the settings for latency-aware request routing.
 *
 * <b>Defaults:</b>
 *
 * <ul>
 *   <li>exclusion_threshold: 2.0</li>
 *   <li>scale_ms: 100 milliseconds</li>
 *   <li>retry_period_ms: 10,000 milliseconds (10 seconds)</li>
 *   <li>update_rate_ms: 100 milliseconds</li>
 *   <li>min_measured: 50</li>
 * </ul>
 *
 * @public @memberof CassCluster
 *
 * @param[in] cluster
 * @param[in] exclusion_threshold Controls how much worse the latency must be compared to the
 * average latency of the best performing node before it penalized.
 * @param[in] scale_ms Controls the weight given to older latencies when calculating the average
 * latency of a node. A bigger scale will give more weight to older latency measurements.
 * @param[in] retry_period_ms The amount of time a node is penalized by the policy before
 * being given a second chance when the current average latency exceeds the calculated
 * threshold (exclusion_threshold * best_average_latency).
 * @param[in] update_rate_ms The rate at  which the best average latency is recomputed.
 * @param[in] min_measured The minimum number of measurements per-host required to
 * be considered by the policy.
 */
CASS_EXPORT void
cass_cluster_set_latency_aware_routing_settings(CassCluster* cluster,
                                                cass_double_t exclusion_threshold,
                                                cass_uint64_t scale_ms,
                                                cass_uint64_t retry_period_ms,
                                                cass_uint64_t update_rate_ms,
                                                cass_uint64_t min_measured);

/**
 * Sets/Appends whitelist hosts. The first call sets the whitelist hosts and
 * any subsequent calls appends additional hosts. Passing an empty string will
 * clear and disable the whitelist. White space is striped from the hosts.
 *
 * This policy filters requests to all other policies, only allowing requests
 * to the hosts contained in the whitelist. Any host not in the whitelist will
 * be ignored and a connection will not be established. This policy is useful
 * for ensuring that the driver will only connect to a predefined set of hosts.
 *
 * Examples: "127.0.0.1" "127.0.0.1,127.0.0.2"
 *
 * @public @memberof CassCluster
 *
 * @param[in] cluster
 * @param[in] hosts A comma delimited list of addresses. An empty string will
 * clear the whitelist hosts. The string is copied into the cluster
 * configuration; the memory pointed to by this parameter can be freed after
 * this call.
 */
CASS_EXPORT void
cass_cluster_set_whitelist_filtering(CassCluster* cluster,
                                     const char* hosts);

/**
 * Same as cass_cluster_set_whitelist_filtering(), but with lengths for
 * string parameters.
 *
 * @public @memberof CassCluster
 *
 * @param[in] cluster
 * @param[in] hosts
 * @param[in] hosts_length
 * @return same as cass_cluster_set_whitelist_filtering()
 *
 * @see cass_cluster_set_whitelist_filtering()
 */
CASS_EXPORT void
cass_cluster_set_whitelist_filtering_n(CassCluster* cluster,
                                       const char* hosts,
                                       size_t hosts_length);

/**
 * Sets/Appends blacklist hosts. The first call sets the blacklist hosts and
 * any subsequent calls appends additional hosts. Passing an empty string will
 * clear and disable the blacklist. White space is striped from the hosts.
 *
 * This policy filters requests to all other policies, only allowing requests
 * to the hosts not contained in the blacklist. Any host in the blacklist will
 * be ignored and a connection will not be established. This policy is useful
 * for ensuring that the driver will not connect to a predefined set of hosts.
 *
 * Examples: "127.0.0.1" "127.0.0.1,127.0.0.2"
 *
 * @public @memberof CassCluster
 *
 * @param[in] cluster
 * @param[in] hosts A comma delimited list of addresses. An empty string will
 * clear the blacklist hosts. The string is copied into the cluster
 * configuration; the memory pointed to by this parameter can be freed after
 * this call.
 */
CASS_EXPORT void
cass_cluster_set_blacklist_filtering(CassCluster* cluster,
                                     const char* hosts);

/**
 * Same as cass_cluster_set_blacklist_filtering_hosts(), but with lengths for
 * string parameters.
 *
 * @public @memberof CassCluster
 *
 * @param[in] cluster
 * @param[in] hosts
 * @param[in] hosts_length
 * @return same as cass_cluster_set_blacklist_filtering()
 *
 * @see cass_cluster_set_blacklist_filtering()
 */
CASS_EXPORT void
cass_cluster_set_blacklist_filtering_n(CassCluster* cluster,
                                       const char* hosts,
                                       size_t hosts_length);

/**
 * Same as cass_cluster_set_whitelist_filtering(), but whitelist all hosts of a dc
 *
 * Examples: "dc1", "dc1,dc2"
 *
 * @public @memberof CassCluster
 *
 * @param[in] cluster
 * @param[in] dcs A comma delimited list of dcs. An empty string will clear the
 * whitelist dcs. The string is copied into the cluster configuration; the
 * memory pointed to by this parameter can be freed after this call.
 */
CASS_EXPORT void
cass_cluster_set_whitelist_dc_filtering(CassCluster* cluster,
                                        const char* dcs);

/**
 * Same as cass_cluster_set_whitelist_dc_filtering(), but with lengths for
 * string parameters.
 *
 * @public @memberof CassCluster
 *
 * @param[in] cluster
 * @param[in] dcs
 * @param[in] dcs_length
 * @return same as cass_cluster_set_whitelist_dc_filtering()
 *
 * @see cass_cluster_set_whitelist_dc_filtering()
 */
CASS_EXPORT void
cass_cluster_set_whitelist_dc_filtering_n(CassCluster* cluster,
                                          const char* dcs,
                                          size_t dcs_length);

/**
 * Same as cass_cluster_set_blacklist_filtering(), but blacklist all hosts of a dc
 *
 * Examples: "dc1", "dc1,dc2"
 *
 * @public @memberof CassCluster
 *
 * @param[in] cluster
 * @param[in] dcs A comma delimited list of dcs. An empty string will clear the
 * blacklist dcs. The string is copied into the cluster configuration; the
 * memory pointed to by this parameter can be freed after this call.
 */
CASS_EXPORT void
cass_cluster_set_blacklist_dc_filtering(CassCluster* cluster,
                                        const char* dcs);

/**
 * Same as cass_cluster_set_blacklist_dc_filtering(), but with lengths for
 * string parameters.
 *
 * @public @memberof CassCluster
 *
 * @param[in] cluster
 * @param[in] dcs
 * @param[in] dcs_length
 * @return same as cass_cluster_set_blacklist_dc_filtering()
 *
 * @see cass_cluster_set_blacklist_dc_filtering()
 */
CASS_EXPORT void
cass_cluster_set_blacklist_dc_filtering_n(CassCluster* cluster,
                                          const char* dcs,
                                          size_t dcs_length);

/**
 * Enable/Disable Nagle's algorithm on connections.
 *
 * <b>Default:</b> cass_true (disables Nagle's algorithm).
 *
 * @public @memberof CassCluster
 *
 * @param[in] cluster
 * @param[in] enabled
 */
CASS_EXPORT void
cass_cluster_set_tcp_nodelay(CassCluster* cluster,
                             cass_bool_t enabled);

/**
 * Enable/Disable TCP keep-alive
 *
 * <b>Default:</b> cass_false (disabled).
 *
 * @public @memberof CassCluster
 *
 * @param[in] cluster
 * @param[in] enabled
 * @param[in] delay_secs The initial delay in seconds, ignored when
 * `enabled` is false.
 */
CASS_EXPORT void
cass_cluster_set_tcp_keepalive(CassCluster* cluster,
                               cass_bool_t enabled,
                               unsigned delay_secs);
/**
 * Sets the timestamp generator used to assign timestamps to all requests
 * unless overridden by setting the timestamp on a statement or a batch.
 *
 * <b>Default:</b> Monotonically increasing, client-side timestamp generator.
 *
 * @cassandra{2.1+}
 *
 * @public @memberof CassCluster
 *
 * @param[in] cluster
 * @param[in] timestamp_gen
 *
 * @see cass_statement_set_timestamp()
 * @see cass_batch_set_timestamp()
 */
CASS_EXPORT void
cass_cluster_set_timestamp_gen(CassCluster* cluster,
                               CassTimestampGen* timestamp_gen);

/**
 * Sets the amount of time between heartbeat messages and controls the amount
 * of time the connection must be idle before sending heartbeat messages. This
 * is useful for preventing intermediate network devices from dropping
 * connections.
 *
 * <b>Default:</b> 30 seconds
 *
 * @public @memberof CassCluster
 *
 * @param[in] cluster
 * @param[in] interval_secs Use 0 to disable heartbeat messages
 */
CASS_EXPORT void
cass_cluster_set_connection_heartbeat_interval(CassCluster* cluster,
                                               unsigned interval_secs);

/**
 * Sets the amount of time a connection is allowed to be without a successful
 * heartbeat response before being terminated and scheduled for reconnection.
 *
 * <b>Default:</b> 60 seconds
 *
 * @public @memberof CassCluster
 *
 * @param[in] cluster
 * @param[in] timeout_secs
 */
CASS_EXPORT void
cass_cluster_set_connection_idle_timeout(CassCluster* cluster,
                                         unsigned timeout_secs);

/**
 * Sets the retry policy used for all requests unless overridden by setting
 * a retry policy on a statement or a batch.
 *
 * <b>Default:</b> The same policy as would be created by the function:
 * cass_retry_policy_default_new(). This policy will retry on a read timeout
 * if there was enough replicas, but no data present, on a write timeout if a
 * logged batch request failed to write the batch log, and on a unavailable
 * error it retries using a new host. In all other cases the default policy
 * will return an error.
 *
 * @public @memberof CassCluster
 *
 * @param[in] cluster
 * @param[in] retry_policy
 *
 * @see cass_retry_policy_default_new()
 * @see cass_statement_set_retry_policy()
 * @see cass_batch_set_retry_policy()
 */
CASS_EXPORT void
cass_cluster_set_retry_policy(CassCluster* cluster,
                              CassRetryPolicy* retry_policy);

/**
 * Enable/Disable retrieving and updating schema metadata. If disabled
 * this is allows the driver to skip over retrieving and updating schema
 * metadata and cass_session_get_schema_meta() will always return an empty object.
 * This can be useful for reducing the startup overhead of short-lived sessions.
 *
 * <b>Default:</b> cass_true (enabled).
 *
 * @public @memberof CassCluster
 *
 * @param[in] cluster
 * @param[in] enabled
 *
 * @see cass_session_get_schema_meta()
 */
CASS_EXPORT void
cass_cluster_set_use_schema(CassCluster* cluster,
                            cass_bool_t enabled);

/**
 * Enable/Disable retrieving hostnames for IP addresses using reverse IP lookup.
 *
 * @deprecated Do not use. Using reverse DNS lookup to verify the certificate
 * does not protect against man-in-the-middle attacks. 
 *
 * <b>Default:</b> cass_false (disabled).
 *
 * @public @memberof CassCluster
 *
 * @param[in] cluster
 * @param[in] enabled
 * @return CASS_OK if successful, otherwise an error occurred
 *
 * @see cass_cluster_set_resolve_timeout()
 */
CASS_EXPORT CASS_DEPRECATED(CassError
cass_cluster_set_use_hostname_resolution(CassCluster* cluster,
                                         cass_bool_t enabled));

/**
 * Enable/Disable the randomization of the contact points list.
 *
 * <b>Default:</b> cass_true (enabled).
 *
 * <b>Important:</b> This setting should only be disabled for debugging or
 * tests.
 *
 * @public @memberof CassCluster
 *
 * @param[in] cluster
 * @param[in] enabled
 * @return CASS_OK if successful, otherwise an error occurred
 */
CASS_EXPORT CassError
cass_cluster_set_use_randomized_contact_points(CassCluster* cluster,
                                               cass_bool_t enabled);

/**
 * Enable constant speculative executions with the supplied settings.
 *
 * @public @memberof CassCluster
 *
 * @param[in] cluster
 * @param[in] constant_delay_ms
 * @param[in] max_speculative_executions
 * @return CASS_OK if successful, otherwise an error occurred
 */
CASS_EXPORT CassError
cass_cluster_set_constant_speculative_execution_policy(CassCluster* cluster,
                                                       cass_int64_t constant_delay_ms,
                                                       int max_speculative_executions);

/**
 * Disable speculative executions
 *
 * <b>Default:</b> This is the default speculative execution policy.
 *
 * @public @memberof CassCluster
 *
 * @param[in] cluster
 * @return CASS_OK if successful, otherwise an error occurred
 */
CASS_EXPORT CassError
cass_cluster_set_no_speculative_execution_policy(CassCluster* cluster);

/**
 * Sets the maximum number of "pending write" objects that will be
 * saved for re-use for marshalling new requests. These objects may
 * hold on to a significant amount of memory and reducing the
 * number of these objects may reduce memory usage of the application.
 *
 * The cost of reducing the value of this setting is potentially slower
 * marshalling of requests prior to sending.
 *
 * <b>Default:</b> Max unsigned integer value
 *
 * @public @memberof CassCluster
 *
 * @param[in] cluster
 * @param[in] num_objects
 * @return CASS_OK if successful, otherwise an error occurred.
 */
CASS_EXPORT CassError
cass_cluster_set_max_reusable_write_objects(CassCluster* cluster,
                                            unsigned num_objects);

/**
 * Associates a named execution profile which can be utilized during execution.
 *
 * <b>Note:</b> Once the execution profile is added to a cluster, it is
 * immutable and any changes made to the execution profile must be re-assigned
 * to the cluster before a session connection is established in order for those
 * settings to be utilized during query execution.
 *
 * @public @memberof CassCluster
 *
 * @param[in] cluster
 * @param[in] name
 * @param[in] profile
 * @return CASS_OK if successful, otherwise an error occurred
 *
 * @see cass_batch_set_execution_profile()
 * @see cass_statement_set_execution_profile()
 */
CASS_EXPORT CassError
cass_cluster_set_execution_profile(CassCluster* cluster,
                                   const char* name,
                                   CassExecProfile* profile);

/**
 * Same as cass_cluster_add_execution_profile(), but with lengths for string
 * parameters.
 *
 * @public @memberof CassCluster
 *
 * @param[in] cluster
 * @param[in] name
 * @param[in] name_length
 * @param[in] profile
 * @return same as cass_cluster_set_execution_profile()
 *
 * @see cass_batch_set_execution_profile()
 * @see cass_statement_set_execution_profile()
 */
CASS_EXPORT CassError
cass_cluster_set_execution_profile_n(CassCluster* cluster,
                                     const char* name,
                                     size_t name_length,
                                     CassExecProfile* profile);

/**
 * Prepare statements on all available hosts.
 *
 * <b>Default:</b> cass_true
 *
 * @public @memberof CassCluster
 *
 * @param cluster
 * @param enabled
 * @return CASS_OK if successful, otherwise an error occurred
 */
CASS_EXPORT CassError
cass_cluster_set_prepare_on_all_hosts(CassCluster* cluster,
                                      cass_bool_t enabled);

/**
 * Enable pre-preparing cached prepared statements when existing hosts become
 * available again or when new hosts are added to the cluster.
 *
 * This can help mitigate request latency when executing prepared statements
 * by avoiding an extra round trip in cases where the statement is
 * unprepared on a freshly started server. The main tradeoff is extra background
 * network traffic is required to prepare the statements on hosts as they become
 * available.
 *
 * <b>Default:</b> cass_true
 *
 * @param cluster
 * @param enabled
 * @return CASS_OK if successful, otherwise an error occurred
 */
CASS_EXPORT CassError
cass_cluster_set_prepare_on_up_or_add_host(CassCluster* cluster,
                                           cass_bool_t enabled);

/**
 * Enable the <b>NO_COMPACT</b> startup option.
 *
 * This can help facilitate uninterrupted cluster upgrades where tables using
 * <b>COMPACT_STORAGE</b> will operate in "compatibility mode" for
 * <b>BATCH</b>, <b>DELETE</b>, <b>SELECT</b>, and <b>UPDATE</b> CQL operations.
 *
 * <b>Default:</b> cass_false
 *
 * @cassandra{3.0.16+}
 * @cassandra{3.11.2+}
 * @cassandra{4.0+}
 *
 * @public @memberof CassCluster
 *
 * @param[in] cluster
 * @param[in] enabled
 */
CASS_EXPORT CassError
cass_cluster_set_no_compact(CassCluster* cluster,
                            cass_bool_t enabled);

/**
 * Sets a callback for handling host state changes in the cluster.
 *
 * <b>Note:</b> The callback is invoked only when state changes in the cluster
 * are applicable to the configured load balancing policy(s).
 *
 * @public @memberof CassCluster
 *
 * @param[in] cluster
 * @param[in] callback
 * @param[in] data
 * @return CASS_OK if successful, otherwise and error occurred
 */
CASS_EXPORT CassError
cass_cluster_set_host_listener_callback(CassCluster* cluster,
                                        CassHostListenerCallback callback,
                                        void* data);

/**
 * Sets the secure connection bundle path for processing DBaaS credentials.
 *
 * This will pre-configure a cluster using the credentials format provided by
 * the DBaaS cloud provider.
 *
 * @param[in] cluster
 * @param[in] path Absolute path to DBaaS credentials file.
 * @return CASS_OK if successful, otherwise error occured.
 */
CASS_EXPORT CassError
cass_cluster_set_cloud_secure_connection_bundle(CassCluster* cluster,
                                                const char* path);

/**
 * Same as cass_cluster_set_cloud_secure_connection_bundle(), but with lengths
 * for string parameters.
 *
 * @see cass_cluster_set_cloud_secure_connection_bundle()
 *
 * @param[in] cluster
 * @param[in] path Absolute path to DBaaS credentials file.
 * @param[in] path_length Length of path variable.
 * @return CASS_OK if successful, otherwise error occured.
 */
CASS_EXPORT CassError
cass_cluster_set_cloud_secure_connection_bundle_n(CassCluster* cluster,
                                                  const char* path,
                                                  size_t path_length);

/**
 * Same as cass_cluster_set_cloud_secure_connection_bundle(), but it does not
 * initialize the underlying SSL library implementation. The SSL library still
 * needs to be initialized, but it's up to the client application to handle
 * initialization. This is similar to the function cass_ssl_new_no_lib_init(),
 * and its documentation should be used as a reference to properly initialize
 * the underlying SSL library.
 *
 * @see cass_ssl_new_no_lib_init()
 * @see cass_cluster_set_cloud_secure_connection_bundle()
 *
 * @param[in] cluster
 * @param[in] path Absolute path to DBaaS credentials file.
 * @return CASS_OK if successful, otherwise error occured.
 */
CASS_EXPORT CassError
cass_cluster_set_cloud_secure_connection_bundle_no_ssl_lib_init(CassCluster* cluster,
                                                                const char* path);

/**
 * Same as cass_cluster_set_cloud_secure_connection_bundle_no_ssl_lib_init(),
 * but with lengths for string parameters.
 *
 * @see cass_cluster_set_cloud_secure_connection_bundle_no_ssl_lib_init()
 *
 * @param[in] cluster
 * @param[in] path Absolute path to DBaaS credentials file.
 * @param[in] path_length Length of path variable.
 * @return CASS_OK if successful, otherwise error occured.
 */
CASS_EXPORT CassError
cass_cluster_set_cloud_secure_connection_bundle_no_ssl_lib_init_n(CassCluster* cluster,
                                                                  const char* path,
                                                                  size_t path_length);

/**
 * Set the application name.
 *
 * This is optional; however it provides the server with the application name
 * that can aid in debugging issues with larger clusters where there are a lot
 * of client (or application) connections.
 *
 * @public @memberof CassCluster
 *
 * @param[in] cluster
 * @param[in] application_name
 */
CASS_EXPORT void
cass_cluster_set_application_name(CassCluster* cluster,
                                  const char* application_name);

/**
 * Same as cass_cluster_set_application_name(), but with lengths for string
 * parameters.
 *
 * @public @memberof CassCluster
 *
 * @param[in] cluster
 * @param[in] application_name
 * @param[in] application_name_length
 */
CASS_EXPORT void
cass_cluster_set_application_name_n(CassCluster* cluster,
                                    const char* application_name,
                                    size_t application_name_length);

/**
 * Set the application version.
 *
 * This is optional; however it provides the server with the application
 * version that can aid in debugging issues with large clusters where there are
 * a lot of client (or application) connections that may have different
 * versions in use.
 *
 * @public @memberof CassCluster
 *
 * @param[in] cluster
 * @param[in] application_version
 */

CASS_EXPORT void
cass_cluster_set_application_version(CassCluster* cluster,
                                     const char* application_version);

/**
 * Same as cass_cluster_set_application_version(), but with lengths for string
 * parameters.
 *
 * @public @memberof CassCluster
 *
 * @param[in] cluster
 * @param[in] application_version
 * @param[in] application_version_length
 */
CASS_EXPORT void
cass_cluster_set_application_version_n(CassCluster* cluster,
                                       const char* application_version,
                                       size_t application_version_length);

/**
 * Set the client id.
 *
 * This is optional; however it provides the server with the client ID that can
 * aid in debugging issues with large clusters where there are a lot of client
 * connections.
 *
 * Default: UUID v4 generated (@see cass_session_get_client_id())
 *
 * @public @memberof CassCluster
 *
 * @param[in] cluster
 * @param[in] client_id
 */
CASS_EXPORT void
cass_cluster_set_client_id(CassCluster* cluster, CassUuid client_id);

/**
 * Sets the amount of time between monitor reporting event messages.
 *
 * <b>Default:</b> 300 seconds.
 *
 * @public @memberof CassCluster
 *
 * @param[in] cluster
 * @param[in] interval_secs Use 0 to disable monitor reporting event messages.
 */
CASS_EXPORT void
cass_cluster_set_monitor_reporting_interval(CassCluster* cluster,
                                            unsigned interval_secs);

/**
 * Sets the amount of time after which metric histograms should be refreshed.
 * Upon refresh histograms are reset to zero, effectively dropping any history to
 * that point.  Refresh occurs when a snapshot is requested so ths value should
 * be thought of as a minimum time to refresh.
 *
 * If refresh is not enabled the driver will continue to accumulate histogram
 * data over the life of a session; this is the default behaviour and replicates
 * the behaviour of previous versions.
 *
 * Note that the specified interval must be > 0 otherwise CASS_ERROR_LIB_BAD_PARAMS
 * will be returned.
 *
 * @public @memberof CassCluster
 *
 * @param cluster
 * @param refresh_interval Minimum interval (in milliseconds) for refresh interval
 */
CASS_EXPORT CassError
cass_cluster_set_histogram_refresh_interval(CassCluster* cluster,
                                            unsigned refresh_interval);

/***********************************************************************************
 *
 * Session
 *
 ***********************************************************************************/

/**
 * Creates a new session.
 *
 * @public @memberof CassSession
 *
 * @return Returns a session that must be freed.
 *
 * @see cass_session_free()
 */
CASS_EXPORT CassSession*
cass_session_new();

/**
 * Frees a session instance. If the session is still connected it will be synchronously
 * closed before being deallocated.
 *
 * Important: Do not free a session in a future callback. Freeing a session in a future
 * callback will cause a deadlock.
 *
 * @public @memberof CassSession
 *
 * @param[in] session
 */
CASS_EXPORT void
cass_session_free(CassSession* session);

/**
 * Connects a session.
 *
 * @public @memberof CassSession
 *
 * @param[in] session
 * @param[in] cluster The cluster configuration is copied into the session and
 * is immutable after connection.
 * @return A future that must be freed.
 *
 * @see cass_session_close()
 */
CASS_EXPORT CassFuture*
cass_session_connect(CassSession* session,
                     const CassCluster* cluster);

/**
 * Connects a session and sets the keyspace.
 *
 * @public @memberof CassSession
 *
 * @param[in] session
 * @param[in] cluster The cluster configuration is copied into the session and
 * is immutable after connection.
 * @param[in] keyspace
 * @return A future that must be freed.
 *
 * @see cass_session_close()
 */
CASS_EXPORT CassFuture*
cass_session_connect_keyspace(CassSession* session,
                              const CassCluster* cluster,
                              const char* keyspace);

/**
 * Same as cass_session_connect_keyspace(), but with lengths for string
 * parameters.
 *
 * @public @memberof CassSession
 *
 * @param[in] session
 * @param[in] cluster
 * @param[in] keyspace
 * @param[in] keyspace_length
 * @return same as cass_session_connect_keyspace()
 *
 * @see cass_session_connect_keyspace()
 */
CASS_EXPORT CassFuture*
cass_session_connect_keyspace_n(CassSession* session,
                                const CassCluster* cluster,
                                const char* keyspace,
                                size_t keyspace_length);

/**
 * Closes the session instance, outputs a close future which can
 * be used to determine when the session has been terminated. This allows
 * in-flight requests to finish.
 *
 * @public @memberof CassSession
 *
 * @param[in] session
 * @return A future that must be freed.
 */
CASS_EXPORT CassFuture*
cass_session_close(CassSession* session);

/**
 * Create a prepared statement.
 *
 * @public @memberof CassSession
 *
 * @param[in] session
 * @param[in] query The query is copied into the statement object; the
 * memory pointed to by this parameter can be freed after this call.
 * @return A future that must be freed.
 *
 * @see cass_future_get_prepared()
 */
CASS_EXPORT CassFuture*
cass_session_prepare(CassSession* session,
                     const char* query);

/**
 * Same as cass_session_prepare(), but with lengths for string
 * parameters.
 *
 * @public @memberof CassSession
 *
 * @param[in] session
 * @param[in] query
 * @param[in] query_length
 * @return same as cass_session_prepare()
 *
 * @see cass_session_prepare()
 */
CASS_EXPORT CassFuture*
cass_session_prepare_n(CassSession* session,
                       const char* query,
                       size_t query_length);

/**
 * Create a prepared statement from an existing statement.
 *
 * <b>Note:</b> Bound statements will inherit the keyspace, consistency,
 * serial consistency, request timeout and retry policy of the existing
 * statement.
 *
 * @public @memberof CassSession
 *
 * @param[in] session
 * @param[in] statement
 * @return A future that must be freed.
 *
 * @see cass_future_get_prepared()
 */
CASS_EXPORT CassFuture*
cass_session_prepare_from_existing(CassSession* session,
                                   CassStatement* statement);

/**
 * Execute a query or bound statement.
 *
 * @public @memberof CassSession
 *
 * @param[in] session
 * @param[in] statement
 * @return A future that must be freed.
 *
 * @see cass_future_get_result()
 */
CASS_EXPORT CassFuture*
cass_session_execute(CassSession* session,
                     const CassStatement* statement);

/**
 * Execute a batch statement.
 *
 * @cassandra{2.0+}
 *
 * @public @memberof CassSession
 *
 * @param[in] session
 * @param[in] batch
 * @return A future that must be freed.
 *
 * @see cass_future_get_result()
 */
CASS_EXPORT CassFuture*
cass_session_execute_batch(CassSession* session,
                           const CassBatch* batch);

/**
 * Gets a snapshot of this session's schema metadata. The returned
 * snapshot of the schema metadata is not updated. This function
 * must be called again to retrieve any schema changes since the
 * previous call.
 *
 * @public @memberof CassSession
 *
 * @param[in] session
 * @return A schema instance that must be freed.
 *
 * @see cass_schema_meta_free()
 */
CASS_EXPORT const CassSchemaMeta*
cass_session_get_schema_meta(const CassSession* session);

/**
 * Gets a copy of this session's performance/diagnostic metrics.
 *
 * @public @memberof CassSession
 *
 * @param[in] session
 * @param[out] output
 */
CASS_EXPORT void
cass_session_get_metrics(const CassSession* session,
                         CassMetrics* output);

/**
 * Gets a copy of this session's speculative execution metrics.
 *
 * @public @memberof CassSession
 *
 * @param[in] session
 * @param[out] output
 */
CASS_EXPORT void
cass_session_get_speculative_execution_metrics(const CassSession* session,
                                               CassSpeculativeExecutionMetrics* output);

/**
 * Get the client id.
 *
 * @public @memberof CassSession
 *
 * @param[in] session
 * @return Client id.
 */
CASS_EXPORT CassUuid
cass_session_get_client_id(CassSession* session);

/***********************************************************************************
 *
 * Schema Metadata
 *
 ***********************************************************************************/

/**
 * Frees a schema metadata instance.
 *
 * @public @memberof CassSchemaMeta
 *
 * @param[in] schema_meta
 */
CASS_EXPORT void
cass_schema_meta_free(const CassSchemaMeta* schema_meta);

/**
 * Gets the version of the schema metadata snapshot.
 *
 * @public @memberof CassSchemaMeta
 *
 * @param[in] schema_meta
 *
 * @return The snapshot version.
 */
CASS_EXPORT cass_uint32_t
cass_schema_meta_snapshot_version(const CassSchemaMeta* schema_meta);

/**
 * Gets the version of the connected Cassandra cluster.
 *
 * @public @memberof CassSchemaMeta
 *
 * @param[in] schema_meta
 *
 * @return Cassandra's version
 */
CASS_EXPORT CassVersion
cass_schema_meta_version(const CassSchemaMeta* schema_meta);

/**
 * Gets the keyspace metadata for the provided keyspace name.
 *
 * @public @memberof CassSchemaMeta
 *
 * @param[in] schema_meta
 * @param[in] keyspace
 *
 * @return The metadata for a keyspace. NULL if keyspace does not exist.
 */
CASS_EXPORT const CassKeyspaceMeta*
cass_schema_meta_keyspace_by_name(const CassSchemaMeta* schema_meta,
                                  const char* keyspace);

/**
 * Same as cass_schema_meta_keyspace_by_name(), but with lengths for string
 * parameters.
 *
 * @public @memberof CassSchemaMeta
 *
 * @param[in] schema_meta
 * @param[in] keyspace
 * @param[in] keyspace_length
 * @return same as cass_schema_meta_keyspace_by_name()
 *
 * @see cass_schema_meta_keyspace_by_name()
 */
CASS_EXPORT const CassKeyspaceMeta*
cass_schema_meta_keyspace_by_name_n(const CassSchemaMeta* schema_meta,
                                    const char* keyspace,
                                    size_t keyspace_length);

/**
 * Gets the name of the keyspace.
 *
 * @public @memberof CassKeyspaceMeta
 *
 * @param[in] keyspace_meta
 * @param[out] name
 * @param[out] name_length
 */
CASS_EXPORT void
cass_keyspace_meta_name(const CassKeyspaceMeta* keyspace_meta,
                        const char** name,
                        size_t* name_length);


/**
 * Determine if the keyspace is a virtual keyspace.
 *
 * @public @memberof CassKeyspaceMeta
 *
 * @param[in] keyspace_meta
 * @return cass_true is the keyspace is virtual, otherwise cass_false
 */
CASS_EXPORT cass_bool_t
cass_keyspace_meta_is_virtual(const CassKeyspaceMeta* keyspace_meta);

/**
 * Gets the table metadata for the provided table name.
 *
 * @public @memberof CassKeyspaceMeta
 *
 * @param[in] keyspace_meta
 * @param[in] table
 *
 * @return The metadata for a table. NULL if table does not exist.
 */
CASS_EXPORT const CassTableMeta*
cass_keyspace_meta_table_by_name(const CassKeyspaceMeta* keyspace_meta,
                                 const char* table);

/**
 * Same as cass_keyspace_meta_table_by_name(), but with lengths for string
 * parameters.
 *
 * @public @memberof CassKeyspaceMeta
 *
 * @param[in] keyspace_meta
 * @param[in] table
 * @param[in] table_length
 * @return same as cass_keyspace_meta_table_by_name()
 *
 * @see cass_keyspace_meta_table_by_name()
 */
CASS_EXPORT const CassTableMeta*
cass_keyspace_meta_table_by_name_n(const CassKeyspaceMeta* keyspace_meta,
                                   const char* table,
                                   size_t table_length);

/**
 * Gets the materialized view metadata for the provided view name.
 *
 * @cassandra{3.0+}
 *
 * @public @memberof CassKeyspaceMeta
 *
 * @param[in] keyspace_meta
 * @param[in] view
 *
 * @return The metadata for a view. NULL if view does not exist.
 */
CASS_EXPORT const CassMaterializedViewMeta*
cass_keyspace_meta_materialized_view_by_name(const CassKeyspaceMeta* keyspace_meta,
                                             const char* view);

/**
 * Same as cass_keyspace_meta_materialized_view_by_name(), but with lengths for string
 * parameters.
 *
 * @cassandra{3.0+}
 *
 * @public @memberof CassKeyspaceMeta
 *
 * @param[in] keyspace_meta
 * @param[in] view
 * @param[in] view_length
 * @return same as cass_keyspace_meta_materialized_view_by_name()
 *
 * @see cass_keyspace_meta_materialized_view_by_name()
 */
CASS_EXPORT const CassMaterializedViewMeta*
cass_keyspace_meta_materialized_view_by_name_n(const CassKeyspaceMeta* keyspace_meta,
                                               const char* view,
                                               size_t view_length);

/**
 * Gets the data type for the provided type name.
 *
 * @cassandra{2.1+}
 *
 * @public @memberof CassKeyspaceMeta
 *
 * @param[in] keyspace_meta
 * @param[in] type
 *
 * @return The data type for a user defined type. NULL if type does not exist.
 */
CASS_EXPORT const CassDataType*
cass_keyspace_meta_user_type_by_name(const CassKeyspaceMeta* keyspace_meta,
                                     const char* type);

/**
 * Same as cass_keyspace_meta_type_by_name(), but with lengths for string
 * parameters.
 *
 * @cassandra{2.1+}
 *
 * @public @memberof CassKeyspaceMeta
 *
 * @param[in] keyspace_meta
 * @param[in] type
 * @param[in] type_length
 * @return same as cass_keyspace_meta_type_by_name()
 *
 * @see cass_keyspace_meta_type_by_name()
 */
CASS_EXPORT const CassDataType*
cass_keyspace_meta_user_type_by_name_n(const CassKeyspaceMeta* keyspace_meta,
                                       const char* type,
                                       size_t type_length);

/**
 * Gets the function metadata for the provided function name.
 *
 * @cassandra{2.2+}
 *
 * @public @memberof CassKeyspaceMeta
 *
 * @param[in] keyspace_meta
 * @param[in] name
 * @param[in] arguments A comma delimited list of CQL types (e.g "text,int,...")
 * describing the function's signature.
 *
 * @return The data function for a user defined function. NULL if function does not exist.
 */
CASS_EXPORT const CassFunctionMeta*
cass_keyspace_meta_function_by_name(const CassKeyspaceMeta* keyspace_meta,
                                    const char* name,
                                    const char* arguments);

/**
 * Same as cass_keyspace_meta_function_by_name(), but with lengths for string
 * parameters.
 *
 * @cassandra{2.2+}
 *
 * @public @memberof CassKeyspaceMeta
 *
 * @param[in] keyspace_meta
 * @param[in] name
 * @param[in] name_length
 * @param[in] arguments
 * @param[in] arguments_length
 * @return same as cass_keyspace_meta_function_by_name()
 *
 * @see cass_keyspace_meta_function_by_name()
 */
CASS_EXPORT const CassFunctionMeta*
cass_keyspace_meta_function_by_name_n(const CassKeyspaceMeta* keyspace_meta,
                                      const char* name,
                                      size_t name_length,
                                      const char* arguments,
                                      size_t arguments_length);

/**
 * Gets the aggregate metadata for the provided aggregate name.
 *
 * @cassandra{2.2+}
 *
 * @public @memberof CassKeyspaceMeta
 *
 * @param[in] keyspace_meta
 * @param[in] name
 * @param[in] arguments A comma delimited list of CQL types (e.g "text,int,...")
 * describing the aggregate's signature.
 *
 * @return The data aggregate for a user defined aggregate. NULL if aggregate does not exist.
 */
CASS_EXPORT const CassAggregateMeta*
cass_keyspace_meta_aggregate_by_name(const CassKeyspaceMeta* keyspace_meta,
                                     const char* name,
                                     const char* arguments);

/**
 * Same as cass_keyspace_meta_aggregate_by_name(), but with lengths for string
 * parameters.
 *
 * @cassandra{2.2+}
 *
 * @public @memberof CassKeyspaceMeta
 *
 * @param[in] keyspace_meta
 * @param[in] name
 * @param[in] name_length
 * @param[in] arguments
 * @param[in] arguments_length
 * @return same as cass_keyspace_meta_aggregate_by_name()
 *
 * @see cass_keyspace_meta_aggregate_by_name()
 */
CASS_EXPORT const CassAggregateMeta*
cass_keyspace_meta_aggregate_by_name_n(const CassKeyspaceMeta* keyspace_meta,
                                       const char* name,
                                       size_t name_length,
                                       const char* arguments,
                                       size_t arguments_length);

/**
 * Gets a metadata field for the provided name. Metadata fields allow direct
 * access to the column data found in the underlying "keyspaces" metadata table.
 *
 * @public @memberof CassKeyspaceMeta
 *
 * @param[in] keyspace_meta
 * @param[in] name
 * @return A metadata field value. NULL if the field does not exist.
 */
CASS_EXPORT const CassValue*
cass_keyspace_meta_field_by_name(const CassKeyspaceMeta* keyspace_meta,
                                 const char* name);

/**
 * Same as cass_keyspace_meta_field_by_name(), but with lengths for string
 * parameters.
 *
 * @public @memberof CassKeyspaceMeta
 *
 * @param[in] keyspace_meta
 * @param[in] name
 * @param[in] name_length
 * @return same as cass_keyspace_meta_field_by_name()
 *
 * @see cass_keyspace_meta_field_by_name()
 */
CASS_EXPORT const CassValue*
cass_keyspace_meta_field_by_name_n(const CassKeyspaceMeta* keyspace_meta,
                                   const char* name,
                                   size_t name_length);

/**
 * Gets the name of the table.
 *
 * @public @memberof CassTableMeta
 *
 * @param[in] table_meta
 * @param[out] name
 * @param[out] name_length
 */
CASS_EXPORT void
cass_table_meta_name(const CassTableMeta* table_meta,
                     const char** name,
                     size_t* name_length);

/**
 * Determine if the table is a virtual table.
 *
 * @public @memberof CassTableMeta
 *
 * @param[in] table_meta
 * @return cass_true is the table is virtual, otherwise cass_false
 */
CASS_EXPORT cass_bool_t
cass_table_meta_is_virtual(const CassTableMeta* table_meta);

/**
 * Gets the column metadata for the provided column name.
 *
 * @public @memberof CassTableMeta
 *
 * @param[in] table_meta
 * @param[in] column
 *
 * @return The metadata for a column. NULL if column does not exist.
 */
CASS_EXPORT const CassColumnMeta*
cass_table_meta_column_by_name(const CassTableMeta* table_meta,
                               const char* column);

/**
 * Same as cass_table_meta_column_by_name(), but with lengths for string
 * parameters.
 *
 * @public @memberof CassTableMeta
 *
 * @param[in] table_meta
 * @param[in] column
 * @param[in] column_length
 * @return same as cass_table_meta_column_by_name()
 *
 * @see cass_table_meta_column_by_name()
 */
CASS_EXPORT const CassColumnMeta*
cass_table_meta_column_by_name_n(const CassTableMeta* table_meta,
                                 const char* column,
                                 size_t column_length);

/**
 * Gets the total number of columns for the table.
 *
 * @public @memberof CassTableMeta
 *
 * @param[in] table_meta
 * @return The total column count.
 */
CASS_EXPORT size_t
cass_table_meta_column_count(const CassTableMeta* table_meta);

/**
 * Gets the column metadata for the provided index.
 *
 * @public @memberof CassTableMeta
 *
 * @param[in] table_meta
 * @param[in] index
 * @return The metadata for a column. NULL returned if the index is out of range.
 */
CASS_EXPORT const CassColumnMeta*
cass_table_meta_column(const CassTableMeta* table_meta,
                       size_t index);

/**
 * Gets the index metadata for the provided index name.
 *
 * @public @memberof CassTableMeta
 *
 * @param[in] table_meta
 * @param[in] index
 *
 * @return The metadata for a index. NULL if index does not exist.
 */
CASS_EXPORT const CassIndexMeta*
cass_table_meta_index_by_name(const CassTableMeta* table_meta,
                               const char* index);

/**
 * Same as cass_table_meta_index_by_name(), but with lengths for string
 * parameters.
 *
 * @public @memberof CassTableMeta
 *
 * @param[in] table_meta
 * @param[in] index
 * @param[in] index_length
 * @return same as cass_table_meta_index_by_name()
 *
 * @see cass_table_meta_index_by_name()
 */
CASS_EXPORT const CassIndexMeta*
cass_table_meta_index_by_name_n(const CassTableMeta* table_meta,
                                 const char* index,
                                 size_t index_length);

/**
 * Gets the total number of indexes for the table.
 *
 * @public @memberof CassTableMeta
 *
 * @param[in] table_meta
 * @return The total index count.
 */
CASS_EXPORT size_t
cass_table_meta_index_count(const CassTableMeta* table_meta);

/**
 * Gets the index metadata for the provided index.
 *
 * @public @memberof CassTableMeta
 *
 * @param[in] table_meta
 * @param[in] index
 * @return The metadata for a index. NULL returned if the index is out of range.
 */
CASS_EXPORT const CassIndexMeta*
cass_table_meta_index(const CassTableMeta* table_meta,
                      size_t index);

/**
 * Gets the materialized view metadata for the provided view name.
 *
 * @cassandra{3.0+}
 *
 * @public @memberof CassTableMeta
 *
 * @param[in] table_meta
 * @param[in] view
 *
 * @return The metadata for a view. NULL if view does not exist.
 */
CASS_EXPORT const CassMaterializedViewMeta*
cass_table_meta_materialized_view_by_name(const CassTableMeta* table_meta,
                                          const char* view);

/**
 * Same as cass_table_meta_materialized_view_by_name(), but with lengths for string
 * parameters.
 *
 * @cassandra{3.0+}
 *
 * @public @memberof CassTableMeta
 *
 * @param[in] table_meta
 * @param[in] view
 * @param[in] view_length
 * @return same as cass_table_meta_materialized_view_by_name()
 *
 * @see cass_table_meta_materialized_view_by_name()
 */
CASS_EXPORT const CassMaterializedViewMeta*
cass_table_meta_materialized_view_by_name_n(const CassTableMeta* table_meta,
                                            const char* view,
                                            size_t view_length);

/**
 * Gets the total number of views for the table.
 *
 * @cassandra{3.0+}
 *
 * @public @memberof CassTableMeta
 *
 * @param[in] table_meta
 * @return The total view count.
 */
CASS_EXPORT size_t
cass_table_meta_materialized_view_count(const CassTableMeta* table_meta);

/**
 * Gets the materialized view metadata for the provided index.
 *
 * @cassandra{3.0+}
 *
 * @public @memberof CassTableMeta
 *
 * @param[in] table_meta
 * @param[in] index
 * @return The metadata for a view. NULL returned if the index is out of range.
 */
CASS_EXPORT const CassMaterializedViewMeta*
cass_table_meta_materialized_view(const CassTableMeta* table_meta,
                                  size_t index);

/**
 * Gets the number of columns for the table's partition key.
 *
 * @public @memberof CassTableMeta
 *
 * @param[in] table_meta
 * @return The count for the number of columns in the partition key.
 */
CASS_EXPORT size_t
cass_table_meta_partition_key_count(const CassTableMeta* table_meta);

/**
 * Gets the partition key column metadata for the provided index.
 *
 * @public @memberof CassTableMeta
 *
 * @param[in] table_meta
 * @param[in] index
 * @return The metadata for a column. NULL returned if the index is out of range.
 *
 * @see cass_table_meta_partition_key_count()
 */
CASS_EXPORT const CassColumnMeta*
cass_table_meta_partition_key(const CassTableMeta* table_meta,
                              size_t index);

/**
 * Gets the number of columns for the table's clustering key.
 *
 * @public @memberof CassTableMeta
 *
 * @param[in] table_meta
 * @return The count for the number of columns in the clustering key.
 */
CASS_EXPORT size_t
cass_table_meta_clustering_key_count(const CassTableMeta* table_meta);

/**
 * Gets the clustering key column metadata for the provided index.
 *
 * @public @memberof CassTableMeta
 *
 * @param[in] table_meta
 * @param[in] index
 * @return The metadata for a column. NULL returned if the index is out of range.
 *
 * @see cass_table_meta_clustering_key_count()
 */
CASS_EXPORT const CassColumnMeta*
cass_table_meta_clustering_key(const CassTableMeta* table_meta,
                               size_t index);

/**
 * Gets the clustering order column metadata for the provided index.
 *
 * @public @memberof CassTableMeta
 *
 * @param[in] table_meta
 * @param[in] index
 * @return The clustering order for a column.
 * CASS_CLUSTERING_ORDER_NONE returned if the index is out of range.
 *
 * @see cass_table_meta_clustering_key_count()
 */
CASS_EXPORT CassClusteringOrder
cass_table_meta_clustering_key_order(const CassTableMeta* table_meta,
                                     size_t index);

/**
 * Gets a metadata field for the provided name. Metadata fields allow direct
 * access to the column data found in the underlying "tables" metadata table.
 *
 * @public @memberof CassTableMeta
 *
 * @param[in] table_meta
 * @param[in] name
 * @return A metadata field value. NULL if the field does not exist.
 */
CASS_EXPORT const CassValue*
cass_table_meta_field_by_name(const CassTableMeta* table_meta,
                              const char* name);

/**
 * Same as cass_table_meta_field_by_name(), but with lengths for string
 * parameters.
 *
 * @public @memberof CassTableMeta
 *
 * @param[in] table_meta
 * @param[in] name
 * @param[in] name_length
 * @return same as cass_table_meta_field_by_name()
 *
 * @see cass_table_meta_field_by_name()
 */
CASS_EXPORT const CassValue*
cass_table_meta_field_by_name_n(const CassTableMeta* table_meta,
                                const char* name,
                                size_t name_length);

/**
 * Gets the column metadata for the provided column name.
 *
 * @cassandra{3.0+}
 *
 * @public @memberof CassMaterializedViewMeta
 *
 * @param[in] view_meta
 * @param[in] column
 *
 * @return The metadata for a column. NULL if column does not exist.
 */
CASS_EXPORT const CassColumnMeta*
cass_materialized_view_meta_column_by_name(const CassMaterializedViewMeta* view_meta,
                                           const char* column);

/**
 * Same as cass_materialized_view_meta_column_by_name(), but with lengths for string
 * parameters.
 *
 * @cassandra{3.0+}
 *
 * @public @memberof CassMaterializedViewMeta
 *
 * @param[in] view_meta
 * @param[in] column
 * @param[in] column_length
 * @return same as cass_materialized_view_meta_column_by_name()
 *
 * @see cass_materialized_view_meta_column_by_name()
 */
CASS_EXPORT const CassColumnMeta*
cass_materialized_view_meta_column_by_name_n(const CassMaterializedViewMeta* view_meta,
                                             const char* column,
                                             size_t column_length);

/**
 * Gets the name of the view.
 *
 * @cassandra{3.0+}
 *
 * @public @memberof CassMaterializedViewMeta
 *
 * @param[in] view_meta
 * @param[out] name
 * @param[out] name_length
 */
CASS_EXPORT void
cass_materialized_view_meta_name(const CassMaterializedViewMeta* view_meta,
                                 const char** name,
                                 size_t* name_length);

/**
 * Gets the base table of the view.
 *
 * @cassandra{3.0+}
 *
 * @public @memberof CassMaterializedViewMeta
 *
 * @param[in] view_meta
 *
 * @return The base table for the view.
 */
CASS_EXPORT const CassTableMeta*
cass_materialized_view_meta_base_table(const CassMaterializedViewMeta* view_meta);

/**
 * Gets the total number of columns for the view.
 *
 * @cassandra{3.0+}
 *
 * @public @memberof CassMaterializedViewMeta
 *
 * @param[in] view_meta
 * @return The total column count.
 */
CASS_EXPORT size_t
cass_materialized_view_meta_column_count(const CassMaterializedViewMeta* view_meta);

/**
 * Gets the column metadata for the provided index.
 *
 * @cassandra{3.0+}
 *
 * @public @memberof CassMaterializedViewMeta
 *
 * @param[in] view_meta
 * @param[in] index
 * @return The metadata for a column. NULL returned if the index is out of range.
 */
CASS_EXPORT const CassColumnMeta*
cass_materialized_view_meta_column(const CassMaterializedViewMeta* view_meta,
                                   size_t index);

/**
 * Gets the number of columns for the view's partition key.
 *
 * @cassandra{3.0+}
 *
 * @public @memberof CassMaterializedViewMeta
 *
 * @param[in] view_meta
 * @return The count for the number of columns in the partition key.
 */
CASS_EXPORT size_t
cass_materialized_view_meta_partition_key_count(const CassMaterializedViewMeta* view_meta);

/**
 * Gets the partition key column metadata for the provided index.
 *
 * @cassandra{3.0+}
 *
 * @public @memberof CassMaterializedViewMeta
 *
 * @param[in] view_meta
 * @param[in] index
 * @return The metadata for a column. NULL returned if the index is out of range.
 */
CASS_EXPORT const CassColumnMeta*
cass_materialized_view_meta_partition_key(const CassMaterializedViewMeta* view_meta,
                                          size_t index);

/**
 * Gets the number of columns for the view's clustering key.
 *
 * @cassandra{3.0+}
 *
 * @public @memberof CassMaterializedViewMeta
 *
 * @param[in] view_meta
 * @return The count for the number of columns in the clustering key.
 */
CASS_EXPORT size_t
cass_materialized_view_meta_clustering_key_count(const CassMaterializedViewMeta* view_meta);

/**
 * Gets the clustering key column metadata for the provided index.
 *
 * @cassandra{3.0+}
 *
 * @public @memberof CassMaterializedViewMeta
 *
 * @param[in] view_meta
 * @param[in] index
 * @return The metadata for a column. NULL returned if the index is out of range.
 */
CASS_EXPORT const CassColumnMeta*
cass_materialized_view_meta_clustering_key(const CassMaterializedViewMeta* view_meta,
                                           size_t index);

/**
 * Gets the clustering order column metadata for the provided index.
 *
 * @public @memberof CassMaterializedViewMeta
 *
 * @param[in] view_meta
 * @param[in] index
 * @return The clustering order for a column.
 * CASS_CLUSTERING_ORDER_NONE returned if the index is out of range.
 *
 * @see cass_materialized_view_meta_clustering_key_count()
 */
CASS_EXPORT CassClusteringOrder
cass_materialized_view_meta_clustering_key_order(const CassMaterializedViewMeta* view_meta,
                                                 size_t index);

/**
 * Gets a metadata field for the provided name. Metadata fields allow direct
 * access to the column data found in the underlying "views" metadata view.
 *
 * @cassandra{3.0+}
 *
 * @public @memberof CassMaterializedViewMeta
 *
 * @param[in] view_meta
 * @param[in] name
 * @return A metadata field value. NULL if the field does not exist.
 */
CASS_EXPORT const CassValue*
cass_materialized_view_meta_field_by_name(const CassMaterializedViewMeta* view_meta,
                                          const char* name);

/**
 * Same as cass_materialized_view_meta_field_by_name(), but with lengths for string
 * parameters.
 *
 * @cassandra{3.0+}
 *
 * @public @memberof CassMaterializedViewMeta
 *
 * @param[in] view_meta
 * @param[in] name
 * @param[in] name_length
 * @return same as cass_materialized_view_meta_field_by_name()
 *
 * @see cass_materialized_view_meta_field_by_name()
 */
CASS_EXPORT const CassValue*
cass_materialized_view_meta_field_by_name_n(const CassMaterializedViewMeta* view_meta,
                                            const char* name,
                                            size_t name_length);

/**
 * Gets the name of the column.
 *
 * @public @memberof CassColumnMeta
 *
 * @param[in] column_meta
 * @param[out] name
 * @param[out] name_length
 */
CASS_EXPORT void
cass_column_meta_name(const CassColumnMeta* column_meta,
                      const char** name,
                      size_t* name_length);

/**
 * Gets the type of the column.
 *
 * @public @memberof CassColumnMeta
 *
 * @param[in] column_meta
 * @return The column's type.
 */
CASS_EXPORT CassColumnType
cass_column_meta_type(const CassColumnMeta* column_meta);

/**
 * Gets the data type of the column.
 *
 * @public @memberof CassColumnMeta
 *
 * @param[in] column_meta
 * @return The column's data type.
 */
CASS_EXPORT const CassDataType*
cass_column_meta_data_type(const CassColumnMeta* column_meta);

/**
 * Gets a metadata field for the provided name. Metadata fields allow direct
 * access to the column data found in the underlying "columns" metadata table.
 *
 * @public @memberof CassColumnMeta
 *
 * @param[in] column_meta
 * @param[in] name
 * @return A metadata field value. NULL if the field does not exist.
 */
CASS_EXPORT const CassValue*
cass_column_meta_field_by_name(const CassColumnMeta* column_meta,
                               const char* name);

/**
 * Same as cass_column_meta_field_by_name(), but with lengths for string
 * parameters.
 *
 * @public @memberof CassColumnMeta
 *
 * @param[in] column_meta
 * @param[in] name
 * @param[in] name_length
 * @return same as cass_column_meta_field_by_name()
 *
 * @see cass_column_meta_field_by_name()
 */
CASS_EXPORT const CassValue*
cass_column_meta_field_by_name_n(const CassColumnMeta* column_meta,
                                 const char* name,
                                 size_t name_length);

/**
 * Gets the name of the index.
 *
 * @public @memberof CassIndexMeta
 *
 * @param[in] index_meta
 * @param[out] name
 * @param[out] name_length
 */
CASS_EXPORT void
cass_index_meta_name(const CassIndexMeta* index_meta,
                      const char** name,
                      size_t* name_length);

/**
 * Gets the type of the index.
 *
 * @public @memberof CassIndexMeta
 *
 * @param[in] index_meta
 * @return The index's type.
 */
CASS_EXPORT CassIndexType
cass_index_meta_type(const CassIndexMeta* index_meta);

/**
 * Gets the target of the index.
 *
 * @public @memberof CassIndexMeta
 *
 * @param[in] index_meta
 * @param[out] target
 * @param[out] target_length
 */
CASS_EXPORT void
cass_index_meta_target(const CassIndexMeta* index_meta,
                       const char** target,
                       size_t* target_length);

/**
 * Gets the options of the index.
 *
 * @public @memberof CassIndexMeta
 *
 * @param[in] index_meta
 * @return The index's options.
 */
CASS_EXPORT const CassValue*
cass_index_meta_options(const CassIndexMeta* index_meta);

/**
 * Gets a metadata field for the provided name. Metadata fields allow direct
 * access to the index data found in the underlying "indexes" metadata table.
 *
 * @public @memberof CassIndexMeta
 *
 * @param[in] index_meta
 * @param[in] name
 * @return A metadata field value. NULL if the field does not exist.
 */
CASS_EXPORT const CassValue*
cass_index_meta_field_by_name(const CassIndexMeta* index_meta,
                               const char* name);

/**
 * Same as cass_index_meta_field_by_name(), but with lengths for string
 * parameters.
 *
 * @public @memberof CassIndexMeta
 *
 * @param[in] index_meta
 * @param[in] name
 * @param[in] name_length
 * @return same as cass_index_meta_field_by_name()
 *
 * @see cass_index_meta_field_by_name()
 */
CASS_EXPORT const CassValue*
cass_index_meta_field_by_name_n(const CassIndexMeta* index_meta,
                                 const char* name,
                                 size_t name_length);

/**
 * Gets the name of the function.
 *
 * @cassandra{2.2+}
 *
 * @public @memberof CassFunctionMeta
 *
 * @param[in] function_meta
 * @param[out] name
 * @param[out] name_length
 */
CASS_EXPORT void
cass_function_meta_name(const CassFunctionMeta* function_meta,
                        const char** name,
                        size_t* name_length);

/**
 * Gets the full name of the function. The full name includes the
 * function's name and the function's signature:
 * "name(type1 type2.. typeN)".
 *
 * @cassandra{2.2+}
 *
 * @public @memberof CassFunctionMeta
 *
 * @param[in] function_meta
 * @param[out] full_name
 * @param[out] full_name_length
 */
CASS_EXPORT void
cass_function_meta_full_name(const CassFunctionMeta* function_meta,
                             const char** full_name,
                             size_t* full_name_length);

/**
 * Gets the body of the function.
 *
 * @cassandra{2.2+}
 *
 * @public @memberof CassFunctionMeta
 *
 * @param[in] function_meta
 * @param[out] body
 * @param[out] body_length
 */
CASS_EXPORT void
cass_function_meta_body(const CassFunctionMeta* function_meta,
                        const char** body,
                        size_t* body_length);

/**
 * Gets the language of the function.
 *
 * @cassandra{2.2+}
 *
 * @public @memberof CassFunctionMeta
 *
 * @param[in] function_meta
 * @param[out] language
 * @param[out] language_length
 */
CASS_EXPORT void
cass_function_meta_language(const CassFunctionMeta* function_meta,
                            const char** language,
                            size_t* language_length);

/**
 * Gets whether a function is called on "null".
 *
 * @cassandra{2.2+}
 *
 * @public @memberof CassFunctionMeta
 *
 * @param[in] function_meta
 * @return cass_true if a function is called on null, otherwise cass_false.
 */
CASS_EXPORT cass_bool_t
cass_function_meta_called_on_null_input(const CassFunctionMeta* function_meta);

/**
 * Gets the number of arguments this function takes.
 *
 * @cassandra{2.2+}
 *
 * @public @memberof CassFunctionMeta
 *
 * @param[in] function_meta
 * @return The number of arguments.
 */
CASS_EXPORT size_t
cass_function_meta_argument_count(const CassFunctionMeta* function_meta);

/**
 * Gets the function's argument name and type for the provided index.
 *
 * @cassandra{2.2+}
 *
 * @public @memberof CassFunctionMeta
 *
 * @param[in] function_meta
 * @param[in] index
 * @param[out] name
 * @param[out] name_length
 * @param[out] type
 * @return CASS_OK if successful, otherwise an error occurred
 */
CASS_EXPORT CassError
cass_function_meta_argument(const CassFunctionMeta* function_meta,
                            size_t index,
                            const char** name,
                            size_t* name_length,
                            const CassDataType** type);

/**
 * Gets the function's argument and type for the provided name.
 *
 * @cassandra{2.2+}
 *
 * @public @memberof CassFunctionMeta
 *
 * @param[in] function_meta
 * @param[in] name
 * @return A data type. NULL if the argument does not exist.
 */
CASS_EXPORT const CassDataType*
cass_function_meta_argument_type_by_name(const CassFunctionMeta* function_meta,
                                         const char* name);

/**
 * Same as cass_function_meta_argument_type_by_name(), but with lengths for string
 * parameters.
 *
 * @cassandra{2.2+}
 *
 * @public @memberof CassFunctionMeta
 *
 * @param[in] function_meta
 * @param[in] name
 * @param[in] name_length
 * @return same as cass_function_meta_argument_type_by_name()
 *
 * @see cass_function_meta_argument_type_by_name()
 */
CASS_EXPORT const CassDataType*
cass_function_meta_argument_type_by_name_n(const CassFunctionMeta* function_meta,
                                           const char* name,
                                           size_t name_length);

/**
 * Gets the return type of the function.
 *
 * @cassandra{2.2+}
 *
 * @public @memberof CassFunctionMeta
 *
 * @param[in] function_meta
 * @return The data type returned by the function.
 */
CASS_EXPORT const CassDataType*
cass_function_meta_return_type(const CassFunctionMeta* function_meta);

/**
 * Gets a metadata field for the provided name. Metadata fields allow direct
 * access to the column data found in the underlying "functions" metadata table.
 *
 * @cassandra{2.2+}
 *
 * @public @memberof CassFunctionMeta
 *
 * @param[in] function_meta
 * @param[in] name
 * @return A metadata field value. NULL if the field does not exist.
 */
CASS_EXPORT const CassValue*
cass_function_meta_field_by_name(const CassFunctionMeta* function_meta,
                                 const char* name);

/**
 * Same as cass_function_meta_field_by_name(), but with lengths for string
 * parameters.
 *
 * @cassandra{2.2+}
 *
 * @public @memberof CassFunctionMeta
 *
 * @param[in] function_meta
 * @param[in] name
 * @param[in] name_length
 * @return same as cass_function_meta_field_by_name()
 *
 * @see cass_function_meta_field_by_name()
 */
CASS_EXPORT const CassValue*
cass_function_meta_field_by_name_n(const CassFunctionMeta* function_meta,
                                   const char* name,
                                   size_t name_length);

/**
 * Gets the name of the aggregate.
 *
 * @cassandra{2.2+}
 *
 * @public @memberof CassAggregateMeta
 *
 * @param[in] aggregate_meta
 * @param[out] name
 * @param[out] name_length
 */
CASS_EXPORT void
cass_aggregate_meta_name(const CassAggregateMeta* aggregate_meta,
                         const char** name,
                         size_t* name_length);

/**
 * Gets the full name of the aggregate. The full name includes the
 * aggregate's name and the aggregate's signature:
 * "name(type1 type2.. typeN)".
 *
 * @cassandra{2.2+}
 *
 * @public @memberof CassAggregateMeta
 *
 * @param[in] aggregate_meta
 * @param[out] full_name
 * @param[out] full_name_length
 */
CASS_EXPORT void
cass_aggregate_meta_full_name(const CassAggregateMeta* aggregate_meta,
                              const char** full_name,
                              size_t* full_name_length);

/**
 * Gets the number of arguments this aggregate takes.
 *
 * @cassandra{2.2+}
 *
 * @public @memberof CassAggregateMeta
 *
 * @param[in] aggregate_meta
 * @return The number of arguments.
 */
CASS_EXPORT size_t
cass_aggregate_meta_argument_count(const CassAggregateMeta* aggregate_meta);

/**
 * Gets the aggregate's argument type for the provided index.
 *
 * @cassandra{2.2+}
 *
 * @public @memberof CassAggregateMeta
 *
 * @param[in] aggregate_meta
 * @param[in] index
 * @return The data type for argument. NULL returned if the index is out of range.
 */
CASS_EXPORT const CassDataType*
cass_aggregate_meta_argument_type(const CassAggregateMeta* aggregate_meta,
                                  size_t index);

/**
 * Gets the return type of the aggregate.
 *
 * @cassandra{2.2+}
 *
 * @public @memberof CassAggregateMeta
 *
 * @param[in] aggregate_meta
 * @return The data type returned by the aggregate.
 */
CASS_EXPORT const CassDataType*
cass_aggregate_meta_return_type(const CassAggregateMeta* aggregate_meta);

/**
 * Gets the state type of the aggregate.
 *
 * @cassandra{2.2+}
 *
 * @public @memberof CassAggregateMeta
 *
 * @param[in] aggregate_meta
 * @return The data type of the aggregate's state.
 */
CASS_EXPORT const CassDataType*
cass_aggregate_meta_state_type(const CassAggregateMeta* aggregate_meta);

/**
 * Gets the function metadata for the aggregate's state function.
 *
 * @cassandra{2.2+}
 *
 * @public @memberof CassAggregateMeta
 *
 * @param[in] aggregate_meta
 * @return The function metadata for the state function.
 */
CASS_EXPORT const CassFunctionMeta*
cass_aggregate_meta_state_func(const CassAggregateMeta* aggregate_meta);

/**
 * Gets the function metadata for the aggregates's final function.
 *
 * @cassandra{2.2+}
 *
 * @public @memberof CassAggregateMeta
 *
 * @param[in] aggregate_meta
 * @return The function metadata for the final function.
 */
CASS_EXPORT const CassFunctionMeta*
cass_aggregate_meta_final_func(const CassAggregateMeta* aggregate_meta);

/**
 * Gets the initial condition value for the aggregate.
 *
 * @cassandra{2.2+}
 *
 * <b>Note:</b> The value of the initial condition will always be
 * a "varchar" type for Cassandra 3.0+.
 *
 * @public @memberof CassAggregateMeta
 *
 * @param[in] aggregate_meta
 * @return The value of the initial condition.
 */
CASS_EXPORT const CassValue*
cass_aggregate_meta_init_cond(const CassAggregateMeta* aggregate_meta);

/**
 * Gets a metadata field for the provided name. Metadata fields allow direct
 * access to the column data found in the underlying "aggregates" metadata table.
 *
 * @cassandra{2.2+}
 *
 * @public @memberof CassAggregateMeta
 *
 * @param[in] aggregate_meta
 * @param[in] name
 * @return A metadata field value. NULL if the field does not exist.
 */
CASS_EXPORT const CassValue*
cass_aggregate_meta_field_by_name(const CassAggregateMeta* aggregate_meta,
                                  const char* name);

/**
 * Same as cass_aggregate_meta_field_by_name(), but with lengths for string
 * parameters.
 *
 * @cassandra{2.2+}
 *
 * @public @memberof CassAggregateMeta
 *
 * @param[in] aggregate_meta
 * @param[in] name
 * @param[in] name_length
 * @return same as cass_aggregate_meta_field_by_name()
 *
 * @see cass_aggregate_meta_field_by_name()
 */
CASS_EXPORT const CassValue*
cass_aggregate_meta_field_by_name_n(const CassAggregateMeta* aggregate_meta,
                                    const char* name,
                                    size_t name_length);

/***********************************************************************************
 *
 * SSL
 *
 ************************************************************************************/

/**
 * Creates a new SSL context.
 *
 * @public @memberof CassSsl
 *
 * @return Returns a SSL context that must be freed.
 *
 * @see cass_ssl_free()
 */
CASS_EXPORT CassSsl*
cass_ssl_new();

/**
 * Creates a new SSL context <b>without</b> initializing the underlying library
 * implementation. The integrating application is responsible for
 * initializing the underlying SSL implementation. The driver uses the SSL
 * implmentation from several threads concurrently so it's important that it's
 * properly setup for multithreaded use e.g. lock callbacks for OpenSSL.
 *
 * <b>Important:</b> The SSL library must be initialized before calling this
 * function.
 *
 * When using OpenSSL the following components need to be initialized:
 *
 * SSL_library_init();
 * SSL_load_error_strings();
 * OpenSSL_add_all_algorithms();
 *
 * The following thread-safety callbacks also need to be set:
 *
 * CRYPTO_set_locking_callback(...);
 * CRYPTO_set_id_callback(...);
 *
 * @public @memberof CassSsl
 *
 * @return Returns a SSL context that must be freed.
 *
 * @see cass_ssl_new()
 * @see cass_ssl_free()
 */
CASS_EXPORT CassSsl*
cass_ssl_new_no_lib_init();

/**
 * Frees a SSL context instance.
 *
 * @public @memberof CassSsl
 *
 * @param[in] ssl
 */
CASS_EXPORT void
cass_ssl_free(CassSsl* ssl);

/**
 * Adds a trusted certificate. This is used to verify
 * the peer's certificate.
 *
 * @public @memberof CassSsl
 *
 * @param[in] ssl
 * @param[in] cert PEM formatted certificate string
 * @return CASS_OK if successful, otherwise an error occurred
 */
CASS_EXPORT CassError
cass_ssl_add_trusted_cert(CassSsl* ssl,
                          const char* cert);

/**
 * Same as cass_ssl_add_trusted_cert(), but with lengths for string
 * parameters.
 *
 * @public @memberof CassSsl
 *
 * @param[in] ssl
 * @param[in] cert
 * @param[in] cert_length
 * @return same as cass_ssl_add_trusted_cert()
 *
 * @see cass_ssl_add_trusted_cert()
 */
CASS_EXPORT CassError
cass_ssl_add_trusted_cert_n(CassSsl* ssl,
                            const char* cert,
                            size_t cert_length);

/**
 * Sets verification performed on the peer's certificate.
 *
 * CASS_SSL_VERIFY_NONE - No verification is performed
 * CASS_SSL_VERIFY_PEER_CERT - Certificate is present and valid
 * CASS_SSL_VERIFY_PEER_IDENTITY - IP address matches the certificate's
 * common name or one of its subject alternative names. This implies the
 * certificate is also present.
 * CASS_SSL_VERIFY_PEER_IDENTITY_DNS -  Do not use. This option requires the
 * use of reverse DNS lookup which is not sufficient to protect against
 * man-in-the-middle attacks.
 *
 * <b>Default:</b> CASS_SSL_VERIFY_PEER_CERT
 *
 * @public @memberof CassSsl
 *
 * @param[in] ssl
 * @param[in] flags
 * @return CASS_OK if successful, otherwise an error occurred
 *
 */
CASS_EXPORT void
cass_ssl_set_verify_flags(CassSsl* ssl,
                          int flags);

/**
 * Set client-side certificate chain. This is used to authenticate
 * the client on the server-side. This should contain the entire
 * Certificate chain starting with the certificate itself.
 *
 * @public @memberof CassSsl
 *
 * @param[in] ssl
 * @param[in] cert PEM formatted certificate string
 * @return CASS_OK if successful, otherwise an error occurred
 */
CASS_EXPORT CassError
cass_ssl_set_cert(CassSsl* ssl,
                  const char* cert);

/**
 * Same as cass_ssl_set_cert(), but with lengths for string
 * parameters.
 *
 * @public @memberof CassSsl
 *
 * @param[in] ssl
 * @param[in] cert
 * @param[in] cert_length
 * @return same as cass_ssl_set_cert()
 *
 * @see cass_ssl_set_cert()
 */
CASS_EXPORT CassError
cass_ssl_set_cert_n(CassSsl* ssl,
                    const char* cert,
                    size_t cert_length);

/**
 * Set client-side private key. This is used to authenticate
 * the client on the server-side.
 *
 * @public @memberof CassSsl
 *
 * @param[in] ssl
 * @param[in] key PEM formatted key string
 * @param[in] password used to decrypt key
 * @return CASS_OK if successful, otherwise an error occurred
 */
CASS_EXPORT CassError
cass_ssl_set_private_key(CassSsl* ssl,
                         const char* key,
                         const char* password);

/**
 * Same as cass_ssl_set_private_key(), but with lengths for string
 * parameters.
 *
 * @public @memberof CassSsl
 *
 * @param[in] ssl
 * @param[in] key
 * @param[in] key_length
 * @param[in] password
 * @param[in] password_length
 * @return same as cass_ssl_set_private_key()
 *
 * @see cass_ssl_set_private_key()
 */
CASS_EXPORT CassError
cass_ssl_set_private_key_n(CassSsl* ssl,
                           const char* key,
                           size_t key_length,
                           const char* password,
                           size_t password_length);

/**
 * Set minimum supported client-side protocol version. This will prevent the
 * connection using protocol versions earlier than the specified one. Useful
 * for preventing TLS downgrade attacks.
 *
 * @public @memberof CassSsl
 *
 * @param[in] ssl
 * @param[in] min_version
 * @return CASS_OK if successful, otherwise an error occurred.
 */
CASS_EXPORT CassError
cass_ssl_set_min_protocol_version(CassSsl* ssl, CassSslTlsVersion min_version);

/***********************************************************************************
 *
 * Authenticator
 *
 ************************************************************************************/

/**
 * Gets the IP address of the host being authenticated.
 *
 * @param[in] auth
 * @param[out] address
 *
 * @public @memberof CassAuthenticator
 */
CASS_EXPORT void
cass_authenticator_address(const CassAuthenticator* auth,
                           CassInet* address);

/**
 * Gets the hostname of the host being authenticated.
 *
 * @public @memberof CassAuthenticator
 *
 * @param[in] auth
 * @param[out] length
 * @return A null-terminated string.
 */
CASS_EXPORT const char*
cass_authenticator_hostname(const CassAuthenticator* auth,
                            size_t* length);

/**
 * Gets the class name for the server-side IAuthentication implementation.
 *
 * @public @memberof CassAuthenticator
 *
 * @param[in] auth
 * @param[out] length
 * @return A null-terminated string.
 */
CASS_EXPORT const char*
cass_authenticator_class_name(const CassAuthenticator* auth,
                              size_t* length);

/**
 * Gets the user data created during the authenticator exchange. This
 * is set using cass_authenticator_set_exchange_data().
 *
 * @public @memberof CassAuthenticator
 *
 * @param[in] auth
 * @return User specified exchange data previously set by
 * cass_authenticator_set_exchange_data().
 *
 * @see cass_authenticator_set_exchange_data()
 */
CASS_EXPORT void*
cass_authenticator_exchange_data(CassAuthenticator* auth);

/**
 * Sets the user data to be used during the authenticator exchange.
 *
 * @public @memberof CassAuthenticator
 *
 * @param[in] auth
 * @param[in] exchange_data
 *
 * @see cass_authenticator_exchange_data()
 */
CASS_EXPORT void
cass_authenticator_set_exchange_data(CassAuthenticator* auth,
                                     void* exchange_data);

/**
 * Gets a response token buffer of the provided size.
 *
 * @public @memberof CassAuthenticator
 *
 * @param[in] auth
 * @param[in] size
 * @return A buffer to copy the response token.
 */
CASS_EXPORT char*
cass_authenticator_response(CassAuthenticator* auth,
                            size_t size);

/**
 * Sets the response token.
 *
 * @public @memberof CassAuthenticator
 *
 * @param[in] auth
 * @param[in] response
 * @param[in] response_size
 */
CASS_EXPORT void
cass_authenticator_set_response(CassAuthenticator* auth,
                                const char* response,
                                size_t response_size);

/**
 * Sets an error for the authenticator exchange.
 *
 * @public @memberof CassAuthenticator
 *
 * @param[in] auth
 * @param[in] message
 */
CASS_EXPORT void
cass_authenticator_set_error(CassAuthenticator* auth,
                             const char* message);

/**
 * Same as cass_authenticator_set_error(), but with lengths for string
 * parameters.
 *
 * @public @memberof CassAuthenticator
 *
 * @param[in] auth
 * @param[in] message
 * @param[in] message_length
 *
 * @see cass_authenticator_set_error()
 */
CASS_EXPORT void
cass_authenticator_set_error_n(CassAuthenticator* auth,
                               const char* message,
                               size_t message_length);

/***********************************************************************************
 *
 * Future
 *
 ***********************************************************************************/

/**
 * Frees a future instance. A future can be freed anytime.
 *
 * @public @memberof CassFuture
 */
CASS_EXPORT void
cass_future_free(CassFuture* future);

/**
 * Sets a callback that is called when a future is set
 *
 * @public @memberof CassFuture
 *
 * @param[in] future
 * @param[in] callback
 * @param[in] data
 * @return CASS_OK if successful, otherwise an error occurred
 */
CASS_EXPORT CassError
cass_future_set_callback(CassFuture* future,
                         CassFutureCallback callback,
                         void* data);

/**
 * Gets the set status of the future.
 *
 * @public @memberof CassFuture
 *
 * @param[in] future
 * @return true if set
 */
CASS_EXPORT cass_bool_t
cass_future_ready(CassFuture* future);

/**
 * Wait for the future to be set with either a result or error.
 *
 * <b>Important:</b> Do not wait in a future callback. Waiting in a future
 * callback will cause a deadlock.
 *
 * @public @memberof CassFuture
 *
 * @param[in] future
 */
CASS_EXPORT void
cass_future_wait(CassFuture* future);

/**
 * Wait for the future to be set or timeout.
 *
 * @public @memberof CassFuture
 *
 * @param[in] future
 * @param[in] timeout_us wait time in microseconds
 * @return false if returned due to timeout
 */
CASS_EXPORT cass_bool_t
cass_future_wait_timed(CassFuture* future,
                       cass_duration_t timeout_us);

/**
 * Gets the result of a successful future. If the future is not ready this method will
 * wait for the future to be set.
 *
 * @public @memberof CassFuture
 *
 * @param[in] future
 * @return CassResult instance if successful, otherwise NULL for error. The return instance
 * must be freed using cass_result_free().
 *
 * @see cass_session_execute() and cass_session_execute_batch()
 */
CASS_EXPORT const CassResult*
cass_future_get_result(CassFuture* future);

/**
 * Gets the error result from a future that failed as a result of a server error. If the
 * future is not ready this method will wait for the future to be set.
 *
 * @public @memberof CassFuture
 *
 * @param[in] future
 * @return CassErrorResult instance if the request failed with a server error,
 * otherwise NULL if the request was successful or the failure was not caused by
 * a server error. The return instance must be freed using cass_error_result_free().
 *
 * @see cass_session_execute() and cass_session_execute_batch()
 */
CASS_EXPORT const CassErrorResult*
cass_future_get_error_result(CassFuture* future);

/**
 * Gets the result of a successful future. If the future is not ready this method will
 * wait for the future to be set. The first successful call consumes the future, all
 * subsequent calls will return NULL.
 *
 * @public @memberof CassFuture
 *
 * @param[in] future
 * @return CassPrepared instance if successful, otherwise NULL for error. The return instance
 * must be freed using cass_prepared_free().
 *
 * @see cass_session_prepare()
 */
CASS_EXPORT const CassPrepared*
cass_future_get_prepared(CassFuture* future);

/**
 * Gets the error code from future. If the future is not ready this method will
 * wait for the future to be set.
 *
 * @public @memberof CassFuture
 *
 * @param[in] future
 * @return CASS_OK if successful, otherwise an error occurred.
 *
 * @see cass_error_desc()
 */
CASS_EXPORT CassError
cass_future_error_code(CassFuture* future);

/**
 * Gets the error message from future. If the future is not ready this method will
 * wait for the future to be set.
 *
 * @public @memberof CassFuture
 *
 * @param[in] future
 * @param[out] message Empty string returned if successful, otherwise
 * a message describing the error is returned.
 * @param[out] message_length
 */
CASS_EXPORT void
cass_future_error_message(CassFuture* future,
                          const char** message,
                          size_t* message_length);

/**
 * Gets the tracing ID associated with the request.
 *
 * @public @memberof CassFuture
 *
 * @param[in] future
 * @param[out] tracing_id
 * @return CASS_OK if successful, otherwise an error occurred.
 */
CASS_EXPORT CassError
cass_future_tracing_id(CassFuture* future,
                       CassUuid* tracing_id);

/**
 * Gets a the number of custom payload items from a response future. If the future is not
 * ready this method will wait for the future to be set.
 *
 * @cassandra{2.2+}
 *
 * @public @memberof CassFuture
 *
 * @param[in] future
 * @return the number of custom payload items.
 */
CASS_EXPORT size_t
cass_future_custom_payload_item_count(CassFuture* future);

/**
 * Gets a custom payload item from a response future at the specified index. If the future is not
 * ready this method will wait for the future to be set.
 *
 * @cassandra{2.2+}
 *
 * @public @memberof CassFuture
 *
 * @param[in] future
 * @param[in] index
 * @param[out] name
 * @param[out] name_length
 * @param[out] value
 * @param[out] value_size
 * @return CASS_OK if successful, otherwise an error occurred.
 */
CASS_EXPORT CassError
cass_future_custom_payload_item(CassFuture* future,
                                size_t index,
                                const char** name,
                                size_t* name_length,
                                const cass_byte_t** value,
                                size_t* value_size);

/**
 * Gets the node that acted as coordinator for this query. If the future is not
 * ready this method will wait for the future to be set.
 *
 * @public @memberof CassFuture
 *
 * @param future
 * @return The coordinator node that handled the query. The lifetime of this
 * object is the same as the result object it came from. NULL can be returned
 * if the future is not a response future or if an error occurs before a
 * coordinator responds.
 *
 * @see cass_statement_set_node()
 */
CASS_EXPORT const CassNode*
cass_future_coordinator(CassFuture* future);

/***********************************************************************************
 *
 * Statement
 *
 ***********************************************************************************/

/**
 * Creates a new query statement.
 *
 * @public @memberof CassStatement
 *
 * @param[in] query The query is copied into the statement object; the
 * memory pointed to by this parameter can be freed after this call.
 * @param[in] parameter_count The number of bound parameters.
 * @return Returns a statement that must be freed.
 *
 * @see cass_statement_free()
 */
CASS_EXPORT CassStatement*
cass_statement_new(const char* query,
                   size_t parameter_count);

/**
 * Same as cass_statement_new(), but with lengths for string
 * parameters.
 *
 * @public @memberof CassStatement
 *
 * @param[in] query
 * @param[in] query_length
 * @param[in] parameter_count
 * @return same as cass_statement_new()
 *
 * @see cass_statement_new()
 */
CASS_EXPORT CassStatement*
cass_statement_new_n(const char* query,
                     size_t query_length,
                     size_t parameter_count);

/**
 * Clear and/or resize the statement's parameters.
 *
 * @public @memberof CassStatement
 *
 * @param[in] statement
 * @param[in] count
 * @return CASS_OK if successful, otherwise an error occurred.
 */
CASS_EXPORT CassError
cass_statement_reset_parameters(CassStatement* statement,
                                 size_t count);

/**
 * Frees a statement instance. Statements can be immediately freed after
 * being prepared, executed or added to a batch.
 *
 * @public @memberof CassStatement
 *
 * @param[in] statement
 */
CASS_EXPORT void
cass_statement_free(CassStatement* statement);

/**
 * Adds a key index specifier to this a statement.
 * When using token-aware routing, this can be used to tell the driver which
 * parameters within a non-prepared, parameterized statement are part of
 * the partition key.
 *
 * Use consecutive calls for composite partition keys.
 *
 * This is not necessary for prepared statements, as the key
 * parameters are determined in the metadata processed in the prepare phase.
 *
 * @public @memberof CassStatement
 *
 * @param[in] statement
 * @param[in] index
 * @return CASS_OK if successful, otherwise an error occurred.
 */
CASS_EXPORT CassError
cass_statement_add_key_index(CassStatement* statement,
                             size_t index);

/**
 * Sets the statement's keyspace. This is used for token-aware routing and when
 * using protocol v5 or greater it also overrides the session's current
 * keyspace for the statement.
 *
 * This is not necessary and will not work for bound statements, as the keyspace
 * is determined by the prepared statement metadata.
 *
 * @public @memberof CassStatement
 *
 * @param[in] statement
 * @param[in] keyspace
 * @return CASS_OK if successful, otherwise an error occurred.
 */
CASS_EXPORT CassError
cass_statement_set_keyspace(CassStatement* statement,
                            const char* keyspace);

/**
 * Same as cass_statement_set_keyspace(), but with lengths for string
 * parameters.
 *
 * @public @memberof CassStatement
 *
 * @param[in] statement
 * @param[in] keyspace
 * @param[in] keyspace_length
 * @return same as cass_statement_set_keyspace()
 *
 * @see cass_statement_set_keyspace()
 */
CASS_EXPORT CassError
cass_statement_set_keyspace_n(CassStatement* statement,
                              const char* keyspace,
                              size_t keyspace_length);

/**
 * Sets the statement's consistency level.
 *
 * <b>Default:</b> CASS_CONSISTENCY_LOCAL_ONE
 *
 * @public @memberof CassStatement
 *
 * @param[in] statement
 * @param[in] consistency
 * @return CASS_OK if successful, otherwise an error occurred.
 */
CASS_EXPORT CassError
cass_statement_set_consistency(CassStatement* statement,
                               CassConsistency consistency);

/**
 * Sets the statement's serial consistency level.
 *
 * @cassandra{2.0+}
 *
 * <b>Default:</b> Not set
 *
 * @public @memberof CassStatement
 *
 * @param[in] statement
 * @param[in] serial_consistency
 * @return CASS_OK if successful, otherwise an error occurred.
 */
CASS_EXPORT CassError
cass_statement_set_serial_consistency(CassStatement* statement,
                                      CassConsistency serial_consistency);

/**
 * Sets the statement's page size.
 *
 * @cassandra{2.0+}
 *
 * <b>Default:</b> -1 (Disabled)
 *
 * @public @memberof CassStatement
 *
 * @param[in] statement
 * @param[in] page_size
 * @return CASS_OK if successful, otherwise an error occurred.
 */
CASS_EXPORT CassError
cass_statement_set_paging_size(CassStatement* statement,
                               int page_size);

/**
 * Sets the statement's paging state. This can be used to get the next page of
 * data in a multi-page query.
 *
 * @cassandra{2.0+}
 *
 * @public @memberof CassStatement
 *
 * @param[in] statement
 * @param[in] result
 * @return CASS_OK if successful, otherwise an error occurred.
 */
CASS_EXPORT CassError
cass_statement_set_paging_state(CassStatement* statement,
                                const CassResult* result);

/**
 * Sets the statement's paging state. This can be used to get the next page of
 * data in a multi-page query.
 *
 * @cassandra{2.0+}
 *
 * <b>Warning:</b> The paging state should not be exposed to or come from
 * untrusted environments. The paging state could be spoofed and potentially
 * used to gain access to other data.
 *
 * @public @memberof CassStatement
 *
 * @param[in] statement
 * @param[in] paging_state
 * @param[in] paging_state_size
 * @return CASS_OK if successful, otherwise an error occurred.
 *
 * @see cass_result_paging_state_token()
 */
CASS_EXPORT CassError
cass_statement_set_paging_state_token(CassStatement* statement,
                                      const char* paging_state,
                                      size_t paging_state_size);

/**
 * Sets the statement's timestamp.
 *
 * @cassandra{2.1+}
 *
 * @public @memberof CassStatement
 *
 * @param[in] statement
 * @param[in] timestamp
 * @return CASS_OK if successful, otherwise an error occurred.
 */
CASS_EXPORT CassError
cass_statement_set_timestamp(CassStatement* statement,
                             cass_int64_t timestamp);

/**
 * Sets the statement's timeout for waiting for a response from a node.
 *
 * <b>Default:</b> Disabled (use the cluster-level request timeout)
 *
 * @public @memberof CassStatement
 *
 * @param[in] statement
 * @param[in] timeout_ms Request timeout in milliseconds. Use 0 for no timeout
 * or CASS_UINT64_MAX to disable (to use the cluster-level request timeout).
 * @return CASS_OK if successful, otherwise an error occurred.
 *
 * @see cass_cluster_set_request_timeout()
 */
CASS_EXPORT CassError
cass_statement_set_request_timeout(CassStatement* statement,
                                   cass_uint64_t timeout_ms);

/**
 * Sets whether the statement is idempotent. Idempotent statements are able to be
 * automatically retried after timeouts/errors and can be speculatively executed.
 *
 * @public @memberof CassStatement
 *
 * @param[in] statement
 * @param[in] is_idempotent
 * @return CASS_OK if successful, otherwise an error occurred.
 *
 * @see cass_cluster_set_constant_speculative_execution_policy()
 * @see cass_execution_profile_set_constant_speculative_execution_policy()
 */
CASS_EXPORT CassError
cass_statement_set_is_idempotent(CassStatement* statement,
                                 cass_bool_t is_idempotent);

/**
 * Sets the statement's retry policy.
 *
 * @public @memberof CassStatement
 *
 * @param[in] statement
 * @param[in] retry_policy
 * @return CASS_OK if successful, otherwise an error occurred.
 */
CASS_EXPORT CassError
cass_statement_set_retry_policy(CassStatement* statement,
                                CassRetryPolicy* retry_policy);

/**
 * Sets the statement's custom payload.
 *
 * @cassandra{2.2+}
 *
 * @public @memberof CassStatement
 *
 * @param[in] statement
 * @param[in] payload
 * @return CASS_OK if successful, otherwise an error occurred.
 */
CASS_EXPORT CassError
cass_statement_set_custom_payload(CassStatement* statement,
                                  const CassCustomPayload* payload);

/**
 * Sets the execution profile to execute the statement with.
 *
 * <b>Note:</b> NULL or empty string will clear execution profile from statement
 *
 * @public @memberof CassStatement
 *
 * @param[in] statement
 * @param[in] name
 * @return CASS_OK if successful, otherwise an error occurred.
 *
 * @see cass_cluster_set_execution_profile()
 */
CASS_EXPORT CassError
cass_statement_set_execution_profile(CassStatement* statement,
                                     const char* name);

/**
 * Same as cass_statement_set_execution_profile(), but with lengths for string
 * parameters.
 *
 * @public @memberof CassStatement
 *
 * @param[in] statement
 * @param[in] name
 * @param[in] name_length
 * @return CASS_OK if successful, otherwise an error occurred.
 *
 * @see cass_statement_set_execution_profile()
 */
CASS_EXPORT CassError
cass_statement_set_execution_profile_n(CassStatement* statement,
                                       const char* name,
                                       size_t name_length);

/**
 * Sets whether the statement should use tracing.
 *
 * @cassandra{2.2+}
 *
 * @public @memberof CassStatement
 *
 * @param[in] statement
 * @param[in] enabled
 * @return CASS_OK if successful, otherwise an error occurred.
 */
CASS_EXPORT CassError
cass_statement_set_tracing(CassStatement* statement,
                           cass_bool_t enabled);

/**
 * Sets a specific host that should run the query.
 *
 * In general, this should not be used, but it can be useful in the following
 * situations:
 * * To query node-local tables such as system and virtual tables.
 * * To apply a sequence of schema changes where it makes sense for all the
 *   changes to be applied on a single node.
 *
 * @public @memberof CassStatement
 *
 * @param[in] statement
 * @param[in] host
 * @param[in] port
 * @return CASS_OK if successful, otherwise an error occurred.
 */
CASS_EXPORT CassError
cass_statement_set_host(CassStatement* statement,
                        const char* host,
                        int port);

/**
 * Same as cass_statement_set_host(), but with lengths for string
 * parameters.
 *
 * @public @memberof CassStatement
 *
 * @param[in] statement
 * @param[in] host
 * @param[in] host_length
 * @param[in] port
 * @return CASS_OK if successful, otherwise an error occurred.
 */
CASS_EXPORT CassError
cass_statement_set_host_n(CassStatement* statement,
                          const char* host,
                          size_t host_length,
                          int port);

/**
 * Same as cass_statement_set_host(), but with the `CassInet` type
 * for the host instead of a string.
 *
 * @public @memberof CassStatement
 *
 * @param[in] statement
 * @param[in] host
 * @param[in] port
 * @return CASS_OK if successful, otherwise an error occurred.
 */
CASS_EXPORT CassError
cass_statement_set_host_inet(CassStatement* statement,
                             const CassInet* host,
                             int port);

/**
 * Same as cass_statement_set_host(), but using the `CassNode` type. This can
 * be used to re-query the same coordinator when used with the result of
 * `cass_future_coordinator()`
 *
 * @public @memberof CassStatement
 *
 * @param statement
 * @param node
 * @return CASS_OK if successful, otherwise an error occurred.
 *
 * @see cass_future_coordinator()
 */
CASS_EXPORT CassError
cass_statement_set_node(CassStatement* statement,
                        const CassNode* node);

/**
 * Binds null to a query or bound statement at the specified index.
 *
 * @public @memberof CassStatement
 *
 * @param[in] statement
 * @param[in] index
 * @return CASS_OK if successful, otherwise an error occurred.
 */
CASS_EXPORT CassError
cass_statement_bind_null(CassStatement* statement,
                         size_t index);

/**
 * Binds a null to all the values with the specified name.
 *
 * This can only be used with statements created by
 * cass_prepared_bind() when using Cassandra 2.0 or earlier.
 *
 * @public @memberof CassStatement
 *
 * @param[in] statement
 * @param[in] name
 * @return CASS_OK if successful, otherwise an error occurred.
 */
CASS_EXPORT CassError
cass_statement_bind_null_by_name(CassStatement* statement,
                                 const char* name);

/**
 * Same as cass_statement_bind_null_by_name(), but with lengths for string
 * parameters.
 *
 * @public @memberof CassStatement
 *
 * @param[in] statement
 * @param[in] name
 * @param[in] name_length
 * @return same as cass_statement_bind_null_by_name()
 *
 * @see cass_statement_bind_null_by_name()
 */
CASS_EXPORT CassError
cass_statement_bind_null_by_name_n(CassStatement* statement,
                                   const char* name,
                                   size_t name_length);

/**
 * Binds a "tinyint" to a query or bound statement at the specified index.
 *
 * @cassandra{2.2+}
 *
 * @public @memberof CassStatement
 *
 * @param[in] statement
 * @param[in] index
 * @param[in] value
 * @return CASS_OK if successful, otherwise an error occurred.
 */
CASS_EXPORT CassError
cass_statement_bind_int8(CassStatement* statement,
                         size_t index,
                         cass_int8_t value);

/**
 * Binds a "tinyint" to all the values with the specified name.
 *
 * @cassandra{2.2+}
 *
 * @public @memberof CassStatement
 *
 * @param[in] statement
 * @param[in] name
 * @param[in] value
 * @return CASS_OK if successful, otherwise an error occurred.
 */
CASS_EXPORT CassError
cass_statement_bind_int8_by_name(CassStatement* statement,
                                 const char* name,
                                 cass_int8_t value);

/**
 * Same as cass_statement_bind_int8_by_name(), but with lengths for string
 * parameters.
 *
 * @cassandra{2.2+}
 *
 * @public @memberof CassStatement
 *
 * @param[in] statement
 * @param[in] name
 * @param[in] name_length
 * @param[in] value
 * @return same as cass_statement_bind_int8_by_name()
 *
 * @see cass_statement_bind_int8_by_name()
 */
CASS_EXPORT CassError
cass_statement_bind_int8_by_name_n(CassStatement* statement,
                                   const char* name,
                                   size_t name_length,
                                   cass_int8_t value);

/**
 * Binds an "smallint" to a query or bound statement at the specified index.
 *
 * @cassandra{2.2+}
 *
 * @public @memberof CassStatement
 *
 * @param[in] statement
 * @param[in] index
 * @param[in] value
 * @return CASS_OK if successful, otherwise an error occurred.
 */
CASS_EXPORT CassError
cass_statement_bind_int16(CassStatement* statement,
                          size_t index,
                          cass_int16_t value);

/**
 * Binds an "smallint" to all the values with the specified name.
 *
 * @cassandra{2.2+}
 *
 * @public @memberof CassStatement
 *
 * @param[in] statement
 * @param[in] name
 * @param[in] value
 * @return CASS_OK if successful, otherwise an error occurred.
 */
CASS_EXPORT CassError
cass_statement_bind_int16_by_name(CassStatement* statement,
                                  const char* name,
                                  cass_int16_t value);

/**
 * Same as cass_statement_bind_int16_by_name(), but with lengths for string
 * parameters.
 *
 * @cassandra{2.2+}
 *
 * @public @memberof CassStatement
 *
 * @param[in] statement
 * @param[in] name
 * @param[in] name_length
 * @param[in] value
 * @return same as cass_statement_bind_int16_by_name()
 *
 * @see cass_statement_bind_int16_by_name()
 */
CASS_EXPORT CassError
cass_statement_bind_int16_by_name_n(CassStatement* statement,
                                    const char* name,
                                    size_t name_length,
                                    cass_int16_t value);

/**
 * Binds an "int" to a query or bound statement at the specified index.
 *
 * @public @memberof CassStatement
 *
 * @param[in] statement
 * @param[in] index
 * @param[in] value
 * @return CASS_OK if successful, otherwise an error occurred.
 */
CASS_EXPORT CassError
cass_statement_bind_int32(CassStatement* statement,
                          size_t index,
                          cass_int32_t value);

/**
 * Binds an "int" to all the values with the specified name.
 *
 * This can only be used with statements created by
 * cass_prepared_bind() when using Cassandra 2.0 or earlier.
 *
 * @public @memberof CassStatement
 *
 * @param[in] statement
 * @param[in] name
 * @param[in] value
 * @return CASS_OK if successful, otherwise an error occurred.
 */
CASS_EXPORT CassError
cass_statement_bind_int32_by_name(CassStatement* statement,
                                  const char* name,
                                  cass_int32_t value);

/**
 * Same as cass_statement_bind_int32_by_name(), but with lengths for string
 * parameters.
 *
 * @public @memberof CassStatement
 *
 * @param[in] statement
 * @param[in] name
 * @param[in] name_length
 * @param[in] value
 * @return same as cass_statement_bind_int32_by_name()
 *
 * @see cass_statement_bind_int32_by_name()
 */
CASS_EXPORT CassError
cass_statement_bind_int32_by_name_n(CassStatement* statement,
                                    const char* name,
                                    size_t name_length,
                                    cass_int32_t value);

/**
 * Binds a "date" to a query or bound statement at the specified index.
 *
 * @cassandra{2.2+}
 *
 * @public @memberof CassStatement
 *
 * @param[in] statement
 * @param[in] index
 * @param[in] value
 * @return CASS_OK if successful, otherwise an error occurred.
 */
CASS_EXPORT CassError
cass_statement_bind_uint32(CassStatement* statement,
                           size_t index,
                           cass_uint32_t value);

/**
 * Binds a "date" to all the values with the specified name.
 *
 * @cassandra{2.2+}
 *
 * @public @memberof CassStatement
 *
 * @param[in] statement
 * @param[in] name
 * @param[in] value
 * @return CASS_OK if successful, otherwise an error occurred.
 */
CASS_EXPORT CassError
cass_statement_bind_uint32_by_name(CassStatement* statement,
                                   const char* name,
                                   cass_uint32_t value);

/**
 * Same as cass_statement_bind_uint32_by_name(), but with lengths for string
 * parameters.
 *
 * @cassandra{2.2+}
 *
 * @public @memberof CassStatement
 *
 * @param[in] statement
 * @param[in] name
 * @param[in] name_length
 * @param[in] value
 * @return same as cass_statement_bind_uint32_by_name()
 *
 * @see cass_statement_bind_uint32_by_name()
 */
CASS_EXPORT CassError
cass_statement_bind_uint32_by_name_n(CassStatement* statement,
                                     const char* name,
                                     size_t name_length,
                                     cass_uint32_t value);

/**
 * Binds a "bigint", "counter", "timestamp" or "time" to a query or
 * bound statement at the specified index.
 *
 * @public @memberof CassStatement
 *
 * @param[in] statement
 * @param[in] index
 * @param[in] value
 * @return CASS_OK if successful, otherwise an error occurred.
 */
CASS_EXPORT CassError
cass_statement_bind_int64(CassStatement* statement,
                          size_t index,
                          cass_int64_t value);

/**
 * Binds a "bigint", "counter", "timestamp" or "time" to all values
 * with the specified name.
 *
 * This can only be used with statements created by
 * cass_prepared_bind() when using Cassandra 2.0 or earlier.
 *
 * @public @memberof CassStatement
 *
 * @param[in] statement
 * @param[in] name
 * @param[in] value
 * @return CASS_OK if successful, otherwise an error occurred.
 */
CASS_EXPORT CassError
cass_statement_bind_int64_by_name(CassStatement* statement,
                                  const char* name,
                                  cass_int64_t value);

/**
 * Same as cass_statement_bind_int64_by_name(), but with lengths for string
 * parameters.
 *
 * @public @memberof CassStatement
 *
 * @param[in] statement
 * @param[in] name
 * @param[in] name_length
 * @param[in] value
 * @return same as cass_statement_bind_int64_by_name(0
 *
 * @see cass_statement_bind_int64_by_name()
 */
CASS_EXPORT CassError
cass_statement_bind_int64_by_name_n(CassStatement* statement,
                                    const char* name,
                                    size_t name_length,
                                    cass_int64_t value);

/**
 * Binds a "float" to a query or bound statement at the specified index.
 *
 * @public @memberof CassStatement
 *
 * @param[in] statement
 * @param[in] index
 * @param[in] value
 * @return CASS_OK if successful, otherwise an error occurred.
 */
CASS_EXPORT CassError
cass_statement_bind_float(CassStatement* statement,
                          size_t index,
                          cass_float_t value);

/**
 * Binds a "float" to all the values with the specified name.
 *
 * This can only be used with statements created by
 * cass_prepared_bind() when using Cassandra 2.0 or earlier.
 *
 * @public @memberof CassStatement
 *
 * @param[in] statement
 * @param[in] name
 * @param[in] value
 * @return CASS_OK if successful, otherwise an error occurred.
 */
CASS_EXPORT CassError
cass_statement_bind_float_by_name(CassStatement* statement,
                                  const char* name,
                                  cass_float_t value);

/**
 * Same as cass_statement_bind_float_by_name(), but with lengths for string
 * parameters.
 *
 * @public @memberof CassStatement
 *
 * @param[in] statement
 * @param[in] name
 * @param[in] name_length
 * @param[in] value
 * @return same as cass_statement_bind_float_by_name()
 *
 * @see cass_statement_bind_float_by_name()
 */
CASS_EXPORT CassError
cass_statement_bind_float_by_name_n(CassStatement* statement,
                                    const char* name,
                                    size_t name_length,
                                    cass_float_t value);

/**
 * Binds a "double" to a query or bound statement at the specified index.
 *
 * @public @memberof CassStatement
 *
 * @param[in] statement
 * @param[in] index
 * @param[in] value
 * @return CASS_OK if successful, otherwise an error occurred.
 */
CASS_EXPORT CassError
cass_statement_bind_double(CassStatement* statement,
                           size_t index,
                           cass_double_t value);

/**
 * Binds a "double" to all the values with the specified name.
 *
 * This can only be used with statements created by
 * cass_prepared_bind() when using Cassandra 2.0 or earlier.
 *
 * @public @memberof CassStatement
 *
 * @param[in] statement
 * @param[in] name
 * @param[in] value
 * @return CASS_OK if successful, otherwise an error occurred.
 */
CASS_EXPORT CassError
cass_statement_bind_double_by_name(CassStatement* statement,
                                   const char* name,
                                   cass_double_t value);

/**
 * Same as cass_statement_bind_double_by_name(), but with lengths for string
 * parameters.
 *
 * @public @memberof CassStatement
 *
 * @param[in] statement
 * @param[in] name
 * @param[in] name_length
 * @param[in] value
 * @return same as cass_statement_bind_double_by_name()
 *
 * @see cass_statement_bind_double_by_name()
 */
CASS_EXPORT CassError
cass_statement_bind_double_by_name_n(CassStatement* statement,
                                     const char* name,
                                     size_t name_length,
                                     cass_double_t value);

/**
 * Binds a "boolean" to a query or bound statement at the specified index.
 *
 * @public @memberof CassStatement
 *
 * @param[in] statement
 * @param[in] index
 * @param[in] value
 * @return CASS_OK if successful, otherwise an error occurred.
 */
CASS_EXPORT CassError
cass_statement_bind_bool(CassStatement* statement,
                         size_t index,
                         cass_bool_t value);

/**
 * Binds a "boolean" to all the values with the specified name.
 *
 * This can only be used with statements created by
 * cass_prepared_bind() when using Cassandra 2.0 or earlier.
 *
 * @public @memberof CassStatement
 *
 * @param[in] statement
 * @param[in] name
 * @param[in] value
 * @return CASS_OK if successful, otherwise an error occurred.
 */
CASS_EXPORT CassError
cass_statement_bind_bool_by_name(CassStatement* statement,
                                 const char* name,
                                 cass_bool_t value);

/**
 * Same as cass_statement_bind_bool_by_name(), but with lengths for string
 * parameters.
 *
 * @public @memberof CassStatement
 *
 * @param[in] statement
 * @param[in] name
 * @param[in] name_length
 * @param[in] value
 * @return same as cass_statement_bind_bool_by_name()
 *
 * @see cass_statement_bind_bool_by_name()
 */
CASS_EXPORT CassError
cass_statement_bind_bool_by_name_n(CassStatement* statement,
                                   const char* name,
                                   size_t name_length,
                                   cass_bool_t value);

/**
 * Binds an "ascii", "text" or "varchar" to a query or bound statement
 * at the specified index.
 *
 * @public @memberof CassStatement
 *
 * @param[in] statement
 * @param[in] index
 * @param[in] value The value is copied into the statement object; the
 * memory pointed to by this parameter can be freed after this call.
 * @return CASS_OK if successful, otherwise an error occurred.
 */
CASS_EXPORT CassError
cass_statement_bind_string(CassStatement* statement,
                           size_t index,
                           const char* value);

/**
 * Same as cass_statement_bind_string(), but with lengths for string
 * parameters.
 *
 * @public @memberof CassStatement
 *
 * @param[in] statement
 * @param[in] index
 * @param[in] value
 * @param[in] value_length
 * @return same as cass_statement_bind_string()
 *
 * @see cass_statement_bind_string()
 */
CASS_EXPORT CassError
cass_statement_bind_string_n(CassStatement* statement,
                             size_t index,
                             const char* value,
                             size_t value_length);

/**
 * Binds an "ascii", "text" or "varchar" to all the values
 * with the specified name.
 *
 * This can only be used with statements created by
 * cass_prepared_bind() when using Cassandra 2.0 or earlier.
 *
 * @public @memberof CassStatement
 *
 * @param[in] statement
 * @param[in] name
 * @param[in] value The value is copied into the statement object; the
 * memory pointed to by this parameter can be freed after this call.
 * @return CASS_OK if successful, otherwise an error occurred.
 */
CASS_EXPORT CassError
cass_statement_bind_string_by_name(CassStatement* statement,
                                   const char* name,
                                   const char* value);

/**
 * Same as cass_statement_bind_string_by_name(), but with lengths for string
 * parameters.
 *
 * @public @memberof CassStatement
 *
 * @param[in] statement
 * @param[in] name
 * @param[in] name_length
 * @param[in] value
 * @param[in] value_length
 * @return same as cass_statement_bind_string_by_name()
 *
 * @see cass_statement_bind_string_by_name()
 */
CASS_EXPORT CassError
cass_statement_bind_string_by_name_n(CassStatement* statement,
                                     const char* name,
                                     size_t name_length,
                                     const char* value,
                                     size_t value_length);

/**
 * Binds a "blob", "varint" or "custom" to a query or bound statement at the specified index.
 *
 * @public @memberof CassStatement
 *
 * @param[in] statement
 * @param[in] index
 * @param[in] value The value is copied into the statement object; the
 * memory pointed to by this parameter can be freed after this call.
 * @param[in] value_size
 * @return CASS_OK if successful, otherwise an error occurred.
 */
CASS_EXPORT CassError
cass_statement_bind_bytes(CassStatement* statement,
                          size_t index,
                          const cass_byte_t* value,
                          size_t value_size);

/**
 * Binds a "blob", "varint" or "custom" to all the values with the
 * specified name.
 *
 * This can only be used with statements created by
 * cass_prepared_bind() when using Cassandra 2.0 or earlier.
 *
 * @public @memberof CassStatement
 *
 * @param[in] statement
 * @param[in] name
 * @param[in] value The value is copied into the statement object; the
 * memory pointed to by this parameter can be freed after this call.
 * @param[in] value_size
 * @return CASS_OK if successful, otherwise an error occurred.
 */
CASS_EXPORT CassError
cass_statement_bind_bytes_by_name(CassStatement* statement,
                                  const char* name,
                                  const cass_byte_t* value,
                                  size_t value_size);

/**
 * Same as cass_statement_bind_bytes_by_name(), but with lengths for string
 * parameters.
 *
 * @public @memberof CassStatement
 *
 * @param[in] statement
 * @param[in] name
 * @param[in] name_length
 * @param[in] value
 * @param[in] value_size
 * @return same as cass_statement_bind_bytes_by_name()
 *
 * @see cass_statement_bind_bytes_by_name()
 */
CASS_EXPORT CassError
cass_statement_bind_bytes_by_name_n(CassStatement* statement,
                                    const char* name,
                                    size_t name_length,
                                    const cass_byte_t* value,
                                    size_t value_size);

/**
 * Binds a "custom" to a query or bound statement at the specified index.
 *
 * @public @memberof CassStatement
 *
 * @param[in] statement
 * @param[in] index
 * @param[in] class_name
 * @param[in] value The value is copied into the statement object; the
 * memory pointed to by this parameter can be freed after this call.
 * @param[in] value_size
 * @return CASS_OK if successful, otherwise an error occurred.
 */
CASS_EXPORT CassError
cass_statement_bind_custom(CassStatement* statement,
                           size_t index,
                           const char* class_name,
                           const cass_byte_t* value,
                           size_t value_size);
/**
 * Same as cass_statement_bind_custom(), but with lengths for string
 * parameters.
 *
 * @public @memberof CassStatement
 *
 * @param[in] statement
 * @param[in] index
 * @param[in] class_name
 * @param[in] class_name_length
 * @param[in] value The value is copied into the statement object; the
 * memory pointed to by this parameter can be freed after this call.
 * @param[in] value_size
 * @return CASS_OK if successful, otherwise an error occurred.
 */
CASS_EXPORT CassError
cass_statement_bind_custom_n(CassStatement* statement,
                             size_t index,
                             const char* class_name,
                             size_t class_name_length,
                             const cass_byte_t* value,
                             size_t value_size);

/**
 * Binds a "custom" to all the values with the specified name.
 *
 * This can only be used with statements created by
 * cass_prepared_bind() when using Cassandra 2.0 or earlier.
 *
 * @public @memberof CassStatement
 *
 * @param[in] statement
 * @param[in] name
 * @param[in] class_name
 * @param[in] value The value is copied into the statement object; the
 * memory pointed to by this parameter can be freed after this call.
 * @param[in] value_size
 * @return CASS_OK if successful, otherwise an error occurred.
 */
CASS_EXPORT CassError
cass_statement_bind_custom_by_name(CassStatement* statement,
                                   const char* name,
                                   const char* class_name,
                                   const cass_byte_t* value,
                                   size_t value_size);

/**
 * Same as cass_statement_bind_custom_by_name(), but with lengths for string
 * parameters.
 *
 * @public @memberof CassStatement
 *
 * @param[in] statement
 * @param[in] name
 * @param[in] name_length
 * @param[in] class_name
 * @param[in] class_name_length
 * @param[in] value
 * @param[in] value_size
 * @return same as cass_statement_bind_custom_by_name()
 *
 * @see cass_statement_bind_custom_by_name()
 */
CASS_EXPORT CassError
cass_statement_bind_custom_by_name_n(CassStatement* statement,
                                     const char* name,
                                     size_t name_length,
                                     const char* class_name,
                                     size_t class_name_length,
                                     const cass_byte_t* value,
                                     size_t value_size);

/**
 * Binds a "uuid" or "timeuuid" to a query or bound statement at the specified index.
 *
 * @public @memberof CassStatement
 *
 * @param[in] statement
 * @param[in] index
 * @param[in] value
 * @return CASS_OK if successful, otherwise an error occurred.
 */
CASS_EXPORT CassError
cass_statement_bind_uuid(CassStatement* statement,
                         size_t index,
                         CassUuid value);

/**
 * Binds a "uuid" or "timeuuid" to all the values
 * with the specified name.
 *
 * This can only be used with statements created by
 * cass_prepared_bind() when using Cassandra 2.0 or earlier.
 *
 * @public @memberof CassStatement
 *
 * @param[in] statement
 * @param[in] name
 * @param[in] value
 * @return CASS_OK if successful, otherwise an error occurred.
 */
CASS_EXPORT CassError
cass_statement_bind_uuid_by_name(CassStatement* statement,
                                 const char* name,
                                 CassUuid value);

/**
 * Same as cass_statement_bind_uuid_by_name(), but with lengths for string
 * parameters.
 *
 * @public @memberof CassStatement
 *
 * @param[in] statement
 * @param[in] name
 * @param[in] name_length
 * @param[in] value
 * @return same as cass_statement_bind_uuid_by_name()
 *
 * @see cass_statement_bind_uuid_by_name()
 */
CASS_EXPORT CassError
cass_statement_bind_uuid_by_name_n(CassStatement* statement,
                                   const char* name,
                                   size_t name_length,
                                   CassUuid value);

/**
 * Binds an "inet" to a query or bound statement at the specified index.
 *
 * @public @memberof CassStatement
 *
 * @param[in] statement
 * @param[in] index
 * @param[in] value
 * @return CASS_OK if successful, otherwise an error occurred.
 */
CASS_EXPORT CassError
cass_statement_bind_inet(CassStatement* statement,
                         size_t index,
                         CassInet value);

/**
 * Binds an "inet" to all the values with the specified name.
 *
 * This can only be used with statements created by
 * cass_prepared_bind() when using Cassandra 2.0 or earlier.
 *
 * @public @memberof CassStatement
 *
 * @param[in] statement
 * @param[in] name
 * @param[in] value
 * @return CASS_OK if successful, otherwise an error occurred.
 */
CASS_EXPORT CassError
cass_statement_bind_inet_by_name(CassStatement* statement,
                                 const char* name,
                                 CassInet value);

/**
 * Same as cass_statement_bind_inet_by_name(), but with lengths for string
 * parameters.
 *
 * @public @memberof CassStatement
 *
 * @param[in] statement
 * @param[in] name
 * @param[in] name_length
 * @param[in] value
 * @return same as cass_statement_bind_inet_by_name()
 *
 * @see cass_statement_bind_inet_by_name()
 */
CASS_EXPORT CassError
cass_statement_bind_inet_by_name_n(CassStatement* statement,
                                   const char* name,
                                   size_t name_length,
                                   CassInet value);

/**
 * Bind a "decimal" to a query or bound statement at the specified index.
 *
 * @public @memberof CassStatement
 *
 * @param[in] statement
 * @param[in] index
 * @param[in] varint The value is copied into the statement object; the
 * memory pointed to by this parameter can be freed after this call.
 * @param[in] varint_size
 * @param[in] scale
 * @return CASS_OK if successful, otherwise an error occurred.
 */
CASS_EXPORT CassError
cass_statement_bind_decimal(CassStatement* statement,
                            size_t index,
                            const cass_byte_t* varint,
                            size_t varint_size,
                            cass_int32_t scale);

/**
 * Binds a "decimal" to all the values with the specified name.
 *
 * This can only be used with statements created by
 * cass_prepared_bind() when using Cassandra 2.0 or earlier.
 *
 * @public @memberof CassStatement
 *
 * @param[in] statement
 * @param[in] name
 * @param[in] varint The value is copied into the statement object; the
 * memory pointed to by this parameter can be freed after this call.
 * @param[in] varint_size
 * @param[in] scale
 * @return CASS_OK if successful, otherwise an error occurred.
 */
CASS_EXPORT CassError
cass_statement_bind_decimal_by_name(CassStatement* statement,
                                    const char* name,
                                    const cass_byte_t* varint,
                                    size_t varint_size,
                                    cass_int32_t scale);

/**
 * Same as cass_statement_bind_decimal_by_name(), but with lengths for string
 * parameters.
 *
 * @public @memberof CassStatement
 *
 * @param[in] statement
 * @param[in] name
 * @param[in] name_length
 * @param[in] varint
 * @param[in] varint_size
 * @param[in] scale
 * @return same as cass_statement_bind_decimal_by_name()
 *
 * @see cass_statement_bind_decimal_by_name()
 */
CASS_EXPORT CassError
cass_statement_bind_decimal_by_name_n(CassStatement* statement,
                                      const char* name,
                                      size_t name_length,
                                      const cass_byte_t* varint,
                                      size_t varint_size,
                                      cass_int32_t scale);

/**
 * Binds a "duration" to a query or bound statement at the specified index.
 *
 * @cassandra{3.10+}
 *
 * @public @memberof CassStatement
 *
 * @param[in] statement
 * @param[in] index
 * @param[in] months
 * @param[in] days
 * @param[in] nanos
 * @return CASS_OK if successful, otherwise an error occurred.
 */
CASS_EXPORT CassError
cass_statement_bind_duration(CassStatement* statement,
                             size_t index,
                             cass_int32_t months,
                             cass_int32_t days,
                             cass_int64_t nanos);

/**
 * Binds a "duration" to all the values with the specified name.
 *
 * @cassandra{3.10+}
 *
 * @public @memberof CassStatement
 *
 * @param[in] statement
 * @param[in] name
 * @param[in] months
 * @param[in] days
 * @param[in] nanos
 * @return CASS_OK if successful, otherwise an error occurred.
 */
CASS_EXPORT CassError
cass_statement_bind_duration_by_name(CassStatement* statement,
                                     const char* name,
                                     cass_int32_t months,
                                     cass_int32_t days,
                                     cass_int64_t nanos);

/**
 * Same as cass_statement_bind_duration_by_name(), but with lengths for string
 * parameters.
 *
 * @cassandra{3.10+}
 *
 * @public @memberof CassStatement
 *
 * @param[in] statement
 * @param[in] name
 * @param[in] name_length
 * @param[in] months
 * @param[in] days
 * @param[in] nanos
 * @return same as cass_statement_bind_duration_by_name()
 *
 * @see cass_statement_bind_duration_by_name()
 */
CASS_EXPORT CassError
cass_statement_bind_duration_by_name_n(CassStatement* statement,
                                       const char* name,
                                       size_t name_length,
                                       cass_int32_t months,
                                       cass_int32_t days,
                                       cass_int64_t nanos);

/**
 * Bind a "list", "map" or "set" to a query or bound statement at the
 * specified index.
 *
 * @public @memberof CassStatement
 *
 * @param[in] statement
 * @param[in] index
 * @param[in] collection The collection can be freed after this call.
 * @return CASS_OK if successful, otherwise an error occurred.
 */
CASS_EXPORT CassError
cass_statement_bind_collection(CassStatement* statement,
                               size_t index,
                               const CassCollection* collection);

/**
 * Bind a "list", "map" or "set" to all the values with the
 * specified name.
 *
 * This can only be used with statements created by
 * cass_prepared_bind() when using Cassandra 2.0 or earlier.
 *
 * @public @memberof CassStatement
 *
 * @param[in] statement
 * @param[in] name
 * @param[in] collection The collection can be freed after this call.
 * @return CASS_OK if successful, otherwise an error occurred.
 */
CASS_EXPORT CassError
cass_statement_bind_collection_by_name(CassStatement* statement,
                                       const char* name,
                                       const CassCollection* collection);

/**
 * Same as cass_statement_bind_collection_by_name(), but with lengths for string
 * parameters.
 *
 * @public @memberof CassStatement
 *
 * @param[in] statement
 * @param[in] name
 * @param[in] name_length
 * @param[in] collection
 * @return same as cass_statement_bind_collection_by_name()
 *
 * @see cass_statement_bind_collection_by_name()
 */
CASS_EXPORT CassError
cass_statement_bind_collection_by_name_n(CassStatement* statement,
                                         const char* name,
                                         size_t name_length,
                                         const CassCollection* collection);

/**
 * Bind a "tuple" to a query or bound statement at the specified index.
 *
 * @cassandra{2.1+}
 *
 * @public @memberof CassStatement
 *
 * @param[in] statement
 * @param[in] index
 * @param[in] tuple The tuple can be freed after this call.
 * @return CASS_OK if successful, otherwise an error occurred.
 */
CASS_EXPORT CassError
cass_statement_bind_tuple(CassStatement* statement,
                          size_t index,
                          const CassTuple* tuple);

/**
 * Bind a "tuple" to all the values with the specified name.
 *
 * @cassandra{2.1+}
 *
 * @public @memberof CassStatement
 *
 * @param[in] statement
 * @param[in] name
 * @param[in] tuple The tuple can be freed after this call.
 * @return CASS_OK if successful, otherwise an error occurred.
 */
CASS_EXPORT CassError
cass_statement_bind_tuple_by_name(CassStatement* statement,
                                  const char* name,
                                  const CassTuple* tuple);

/**
 * Same as cass_statement_bind_tuple_by_name(), but with lengths for string
 * parameters.
 *
 * @cassandra{2.1+}
 *
 * @public @memberof CassStatement
 *
 * @param[in] statement
 * @param[in] name
 * @param[in] name_length
 * @param[in] tuple
 * @return same as cass_statement_bind_tuple_by_name()
 *
 * @see cass_statement_bind_tuple_by_name()
 */
CASS_EXPORT CassError
cass_statement_bind_tuple_by_name_n(CassStatement* statement,
                                    const char* name,
                                    size_t name_length,
                                    const CassTuple* tuple);

/**
 * Bind a user defined type to a query or bound statement at the
 * specified index.
 *
 * @cassandra{2.1+}
 *
 * @public @memberof CassStatement
 *
 * @param[in] statement
 * @param[in] index
 * @param[in] user_type The user type can be freed after this call.
 * @return CASS_OK if successful, otherwise an error occurred.
 */
CASS_EXPORT CassError
cass_statement_bind_user_type(CassStatement* statement,
                              size_t index,
                              const CassUserType* user_type);
/**
 * Bind a user defined type to a query or bound statement with the
 * specified name.
 *
 * @cassandra{2.1+}
 *
 * @public @memberof CassStatement
 *
 * @param[in] statement
 * @param[in] name
 * @param[in] user_type The user type can be freed after this call.
 * @return CASS_OK if successful, otherwise an error occurred.
 */
CASS_EXPORT CassError
cass_statement_bind_user_type_by_name(CassStatement* statement,
                                      const char* name,
                                      const CassUserType* user_type);

/**
 * Same as cass_statement_bind_user_type_by_name(), but with lengths for string
 * parameters.
 *
 * @cassandra{2.1+}
 *
 * @public @memberof CassStatement
 *
 * @param[in] statement
 * @param[in] name
 * @param[in] name_length
 * @param[in] user_type
 * @return same as cass_statement_bind_user_type_by_name()
 *
 * @see cass_statement_bind_collection_by_name()
 */
CASS_EXPORT CassError
cass_statement_bind_user_type_by_name_n(CassStatement* statement,
                                        const char* name,
                                        size_t name_length,
                                        const CassUserType* user_type);

/***********************************************************************************
 *
 * Prepared
 *
 ***********************************************************************************/

/**
 * Frees a prepared instance.
 *
 * @public @memberof CassPrepared
 *
 * @param[in] prepared
 */
CASS_EXPORT void
cass_prepared_free(const CassPrepared* prepared);

/**
 * Creates a bound statement from a pre-prepared statement.
 *
 * @public @memberof CassPrepared
 *
 * @param[in] prepared
 * @return Returns a bound statement that must be freed.
 *
 * @see cass_statement_free()
 */
CASS_EXPORT CassStatement*
cass_prepared_bind(const CassPrepared* prepared);

/**
 * Gets the name of a parameter at the specified index.
 *
 * @public @memberof CassPrepared
 *
 * @param[in] prepared
 * @param[in] index
 * @param[out] name
 * @param[out] name_length
 * @return CASS_OK if successful, otherwise an error occurred.
 */
CASS_EXPORT CassError
cass_prepared_parameter_name(const CassPrepared* prepared,
                             size_t index,
                             const char** name,
                             size_t* name_length);

/**
 * Gets the data type of a parameter at the specified index.
 *
 * @public @memberof CassPrepared
 *
 * @param[in] prepared
 * @param[in] index
 * @return Returns a reference to the data type of the parameter. Do not free
 * this reference as it is bound to the lifetime of the prepared.
 */
CASS_EXPORT const CassDataType*
cass_prepared_parameter_data_type(const CassPrepared* prepared,
                                  size_t index);

/**
 * Gets the data type of a parameter for the specified name.
 *
 * @public @memberof CassPrepared
 *
 * @param[in] prepared
 * @param[in] name
 * @return Returns a reference to the data type of the parameter. Do not free
 * this reference as it is bound to the lifetime of the prepared.
 */
CASS_EXPORT const CassDataType*
cass_prepared_parameter_data_type_by_name(const CassPrepared* prepared,
                                          const char* name);

/**
 * Same as cass_prepared_parameter_data_type_by_name(), but with lengths for string
 * parameters.
 *
 * @public @memberof CassPrepared
 *
 * @param[in] prepared
 * @param[in] name
 * @param[in] name_length
 * @return Returns a reference to the data type of the parameter. Do not free
 * this reference as it is bound to the lifetime of the prepared.
 *
 * @see cass_prepared_parameter_data_type_by_name()
 */
CASS_EXPORT const CassDataType*
cass_prepared_parameter_data_type_by_name_n(const CassPrepared* prepared,
                                            const char* name,
                                            size_t name_length);

/***********************************************************************************
 *
 * Batch
 *
 ***********************************************************************************/

/**
 * Creates a new batch statement with batch type.
 *
 * @cassandra{2.0+}
 *
 * @public @memberof CassBatch
 *
 * @param[in] type
 * @return Returns a batch statement that must be freed.
 *
 * @see cass_batch_free()
 */
CASS_EXPORT CassBatch*
cass_batch_new(CassBatchType type);

/**
 * Frees a batch instance. Batches can be immediately freed after being
 * executed.
 *
 * @cassandra{2.0+}
 *
 * @public @memberof CassBatch
 *
 * @param[in] batch
 */
CASS_EXPORT void
cass_batch_free(CassBatch* batch);

/**
 * Sets the batch's keyspace. When using protocol v5 or greater it overrides
 * the session's keyspace for the batch.
 *
 * <b>Note:</b> If not set explicitly then the batch will inherit the keyspace
 * of the first child statement with a non-empty keyspace.
 *
 * @public @memberof CassBatch
 *
 * @param[in] batch
 * @param[in] keyspace
 * @return CASS_OK if successful, otherwise an error occurred.
 */
CASS_EXPORT CassError
cass_batch_set_keyspace(CassBatch* batch,
                        const char* keyspace);

/**
 * Same as cass_batch_set_keyspace(), but with lengths for string
 * parameters.
 *
 * @public @memberof CassBatch
 *
 * @param[in] batch
 * @param[in] keyspace
 * @param[in] keyspace_length
 * @return same as cass_batch_set_keyspace()
 *
 * @see cass_batch_set_keyspace()
 */
CASS_EXPORT CassError
cass_batch_set_keyspace_n(CassBatch* batch,
                          const char* keyspace,
                          size_t keyspace_length);

/**
 * Sets the batch's consistency level
 *
 * @cassandra{2.0+}
 *
 * @public @memberof CassBatch
 *
 * @param[in] batch
 * @param[in] consistency The batch's write consistency.
 * @return CASS_OK if successful, otherwise an error occurred.
 */
CASS_EXPORT CassError
cass_batch_set_consistency(CassBatch* batch,
                           CassConsistency consistency);

/**
 * Sets the batch's serial consistency level.
 *
 * @cassandra{2.0+}
 *
 * <b>Default:</b> Not set
 *
 * @public @memberof CassBatch
 *
 * @param[in] batch
 * @param[in] serial_consistency
 * @return CASS_OK if successful, otherwise an error occurred.
 */
CASS_EXPORT CassError
cass_batch_set_serial_consistency(CassBatch* batch,
                                  CassConsistency serial_consistency);

/**
 * Sets the batch's timestamp.
 *
 * @cassandra{2.1+}
 *
 * @public @memberof CassBatch
 *
 * @param[in] batch
 * @param[in] timestamp
 * @return CASS_OK if successful, otherwise an error occurred.
 */
CASS_EXPORT CassError
cass_batch_set_timestamp(CassBatch* batch,
                         cass_int64_t timestamp);

/**
 * Sets the batch's timeout for waiting for a response from a node.
 *
 * <b>Default:</b> Disabled (use the cluster-level request timeout)
 *
 * @public @memberof CassBatch
 *
 * @param[in] batch
 * @param[in] timeout_ms Request timeout in milliseconds. Use 0 for no timeout
 * or CASS_UINT64_MAX to disable (to use the cluster-level request timeout).
 * @return CASS_OK if successful, otherwise an error occurred.
 *
 * @see cass_cluster_set_request_timeout()
 */
CASS_EXPORT CassError
cass_batch_set_request_timeout(CassBatch* batch,
                               cass_uint64_t timeout_ms);

/**
 * Sets whether the statements in a batch are idempotent. Idempotent batches
 * are able to be automatically retried after timeouts/errors and can be
 * speculatively executed.
 *
 * @public @memberof CassBatch
 *
 * @param[in] batch
 * @param[in] is_idempotent
 * @return CASS_OK if successful, otherwise an error occurred.
 *
 * @see cass_cluster_set_constant_speculative_execution_policy()
 * @see cass_execution_profile_set_constant_speculative_execution_policy()
 */
CASS_EXPORT CassError
cass_batch_set_is_idempotent(CassBatch* batch,
                             cass_bool_t is_idempotent);

/**
 * Sets the batch's retry policy.
 *
 * @cassandra{2.0+}
 *
 * @public @memberof CassBatch
 *
 * @param[in] batch
 * @param[in] retry_policy
 * @return CASS_OK if successful, otherwise an error occurred.
 */
CASS_EXPORT CassError
cass_batch_set_retry_policy(CassBatch* batch,
                            CassRetryPolicy* retry_policy);

/**
 * Sets the batch's custom payload.
 *
 * @cassandra{2.2+}
 *
 * @public @memberof CassBatch
 *
 * @param[in] batch
 * @param[in] payload
 * @return CASS_OK if successful, otherwise an error occurred.
 */
CASS_EXPORT CassError
cass_batch_set_custom_payload(CassBatch* batch,
                              const CassCustomPayload* payload);

/**
 * Sets whether the batch should use tracing.
 *
 * @cassandra{2.2+}
 *
 * @public @memberof CassStatement
 *
 * @param[in] batch
 * @param[in] enabled
 * @return CASS_OK if successful, otherwise an error occurred.
 */
CASS_EXPORT CassError
cass_batch_set_tracing(CassBatch* batch,
                       cass_bool_t enabled);

/**
 * Adds a statement to a batch.
 *
 * @cassandra{2.0+}
 *
 * @public @memberof CassBatch
 *
 * @param[in] batch
 * @param[in] statement
 * @return CASS_OK if successful, otherwise an error occurred.
 */
CASS_EXPORT CassError
cass_batch_add_statement(CassBatch* batch,
                         CassStatement* statement);

/**
 * Sets the execution profile to execute the batch with.
 *
 * <b>Note:</b> NULL or empty string will clear execution profile from batch
 *
 * @public @memberof CassBatch
 *
 * @param[in] batch
 * @param[in] name
 * @return CASS_OK if successful, otherwise an error occurred.
 *
 * @see cass_cluster_set_execution_profile()
 */
CASS_EXPORT CassError
cass_batch_set_execution_profile(CassBatch* batch,
                                 const char* name);

/**
 * Same as cass_batch_set_execution_profile(), but with lengths for string
 * parameters.
 *
 * @public @memberof CassBatch
 *
 * @param[in] batch
 * @param[in] name
 * @param[in] name_length
 * @return CASS_OK if successful, otherwise an error occurred.
 *
 * @see cass_batch_set_execution_profile()
 */
CASS_EXPORT CassError
cass_batch_set_execution_profile_n(CassBatch* batch,
                                   const char* name,
                                   size_t name_length);

/***********************************************************************************
 *
 * Data type
 *
 ***********************************************************************************/

/**
 * Creates a new data type with value type.
 *
 * @public @memberof CassDataType
 *
 * @param[in] type
 * @return Returns a data type that must be freed.
 *
 * @see cass_data_type_free()
 */
CASS_EXPORT CassDataType*
cass_data_type_new(CassValueType type);

/**
 * Creates a new data type from an existing data type.
 *
 * @public @memberof CassDataType
 *
 * @param[in] data_type
 * @return Returns a data type that must be freed.
 *
 * @see cass_data_type_free()
 */
CASS_EXPORT CassDataType*
cass_data_type_new_from_existing(const CassDataType* data_type);

/**
 * Creates a new tuple data type.
 *
 * @cassandra{2.1+}
 *
 * @public @memberof CassDataType
 *
 * @param[in] item_count The number of items in the tuple
 * @return Returns a data type that must be freed.
 *
 * @see cass_data_type_free()
 */
CASS_EXPORT CassDataType*
cass_data_type_new_tuple(size_t item_count);

/**
 * Creates a new UDT (user defined type) data type.
 *
 * @cassandra{2.1+}
 *
 * @public @memberof CassDataType
 *
 * @param[in] field_count The number of fields in the UDT
 * @return Returns a data type that must be freed.
 *
 * @see cass_data_type_free()
 */
CASS_EXPORT CassDataType*
cass_data_type_new_udt(size_t field_count);

/**
 * Frees a data type instance.
 *
 * @public @memberof CassDataType
 *
 * @param[in] data_type
 */
CASS_EXPORT void
cass_data_type_free(CassDataType* data_type);

/**
 * Gets the value type of the specified data type.
 *
 * @param[in] data_type
 * @return The value type
 */
CASS_EXPORT CassValueType
cass_data_type_type(const CassDataType* data_type);

/**
 * Gets whether a data type is frozen.
 *
 * @cassandra{2.1+}
 *
 * @param[in] data_type
 * @return cass_true if the data type is frozen, otherwise cass_false.
 */
CASS_EXPORT cass_bool_t
cass_data_type_is_frozen(const CassDataType* data_type);

/**
 * Gets the type name of a UDT data type.
 *
 * <b>Note:</b> Only valid for UDT data types.
 *
 * @param[in] data_type
 * @param[out] type_name
 * @param[out] type_name_length
 * @return CASS_OK if successful, otherwise an error occurred.
 */
CASS_EXPORT CassError
cass_data_type_type_name(const CassDataType* data_type,
                         const char** type_name,
                         size_t* type_name_length);

/**
 * Sets the type name of a UDT data type.
 *
 * <b>Note:</b> Only valid for UDT data types.
 *
 * @param[in] data_type
 * @param[in] type_name
 * @return CASS_OK if successful, otherwise an error occurred.
 */
CASS_EXPORT CassError
cass_data_type_set_type_name(CassDataType* data_type,
                             const char* type_name);

/**
 * Same as cass_data_type_set_type_name(), but with lengths for string
 * parameters.
 *
 * @public @memberof CassDataType
 *
 * @param[in] data_type
 * @param[in] type_name
 * @param[in] type_name_length
 * @return Returns a data type that must be freed.
 */
CASS_EXPORT CassError
cass_data_type_set_type_name_n(CassDataType* data_type,
                               const char* type_name,
                               size_t type_name_length);

/**
 * Gets the type name of a UDT data type.
 *
 * <b>Note:</b> Only valid for UDT data types.
 *
 * @cassandra{2.1+}
 *
 * @param[in] data_type
 * @param[out] keyspace
 * @param[out] keyspace_length
 * @return CASS_OK if successful, otherwise an error occurred.
 */
CASS_EXPORT CassError
cass_data_type_keyspace(const CassDataType* data_type,
                        const char** keyspace,
                        size_t* keyspace_length);

/**
 * Sets the keyspace of a UDT data type.
 *
 * <b>Note:</b> Only valid for UDT data types.
 *
 * @cassandra{2.1+}
 *
 * @param[in] data_type
 * @param[in] keyspace
 * @return CASS_OK if successful, otherwise an error occurred.
 */
CASS_EXPORT CassError
cass_data_type_set_keyspace(CassDataType* data_type,
                            const char* keyspace);

/**
 * Same as cass_data_type_set_keyspace(), but with lengths for string
 * parameters.
 *
 * @cassandra{2.1+}
 *
 * @public @memberof CassDataType
 *
 * @param[in] data_type
 * @param[in] keyspace
 * @param[in] keyspace_length
 * @return Returns a data type that must be freed.
 */
CASS_EXPORT CassError
cass_data_type_set_keyspace_n(CassDataType* data_type,
                              const char* keyspace,
                              size_t keyspace_length);

/**
 * Gets the class name of a custom data type.
 *
 * <b>Note:</b> Only valid for custom data types.
 *
 * @param[in] data_type
 * @param[out] class_name
 * @param[out] class_name_length
 * @return CASS_OK if successful, otherwise an error occurred.
 */
CASS_EXPORT CassError
cass_data_type_class_name(const CassDataType* data_type,
                          const char** class_name,
                          size_t* class_name_length);

/**
 * Sets the class name of a custom data type.
 *
 * <b>Note:</b> Only valid for custom data types.
 *
 * @param[in] data_type
 * @param[in] class_name
 * @return CASS_OK if successful, otherwise an error occurred.
 */
CASS_EXPORT CassError
cass_data_type_set_class_name(CassDataType* data_type,
                              const char* class_name);

/**
 * Same as cass_data_type_set_class_name(), but with lengths for string
 * parameters.
 *
 * @public @memberof CassDataType
 *
 * @param[in] data_type
 * @param[in] class_name
 * @param[in] class_name_length
 * @return Returns a data type that must be freed.
 */
CASS_EXPORT CassError
cass_data_type_set_class_name_n(CassDataType* data_type,
                                const char* class_name,
                                size_t class_name_length);

/**
 * Gets the sub-data type count of a UDT (user defined type), tuple
 * or collection.
 *
 * <b>Note:</b> Only valid for UDT, tuple and collection data types.
 *
 * @param[in] data_type
 * @return Returns the number of sub-data types
 */
CASS_EXPORT size_t
cass_data_type_sub_type_count(const CassDataType* data_type);

/**
 * @deprecated Use cass_data_type_sub_type_count()
 */
CASS_EXPORT CASS_DEPRECATED(size_t
cass_data_sub_type_count(const CassDataType* data_type));

/**
 * Gets the sub-data type count of a UDT (user defined type), tuple
 * or collection.
 *
 * <b>Note:</b> Only valid for UDT, tuple and collection data types.
 *
 * @param[in] data_type
 * @return Returns the number of sub-data types
 */

/**
 * Gets the sub-data type of a UDT (user defined type), tuple or collection at
 * the specified index.
 *
 * <b>Note:</b> Only valid for UDT, tuple and collection data types.
 *
 * @param[in] data_type
 * @param[in] index
 * @return Returns a reference to a child data type. Do not free this
 * reference as it is bound to the lifetime of the parent data type. NULL
 * is returned if the index is out of range.
 */
CASS_EXPORT const CassDataType*
cass_data_type_sub_data_type(const CassDataType* data_type,
                             size_t index);

/**
 * Gets the sub-data type of a UDT (user defined type) at the specified index.
 *
 * <b>Note:</b> Only valid for UDT data types.
 *
 * @cassandra{2.1+}
 *
 * @param[in] data_type
 * @param[in] name
 * @return Returns a reference to a child data type. Do not free this
 * reference as it is bound to the lifetime of the parent data type. NULL
 * is returned if the name doesn't exist.
 */
CASS_EXPORT const CassDataType*
cass_data_type_sub_data_type_by_name(const CassDataType* data_type,
                                     const char* name);

/**
 * Same as cass_data_type_sub_data_type_by_name(), but with lengths for string
 * parameters.
 *
 * @cassandra{2.1+}
 *
 * @public @memberof CassDataType
 *
 * @param[in] data_type
 * @param[in] name
 * @param[in] name_length
 * @return Returns a reference to a child data type. Do not free this
 * reference as it is bound to the lifetime of the parent data type. NULL
 * is returned if the name doesn't exist.
 */
CASS_EXPORT const CassDataType*
cass_data_type_sub_data_type_by_name_n(const CassDataType* data_type,
                                       const char* name,
                                       size_t name_length);

/**
 * Gets the sub-type name of a UDT (user defined type) at the specified index.
 *
 * @cassandra{2.1+}
 *
 * <b>Note:</b> Only valid for UDT data types.
 *
 * @param[in] data_type
 * @param[in] index
 * @param[out] name
 * @param[out] name_length
 * @return CASS_OK if successful, otherwise an error occurred.
 */
CASS_EXPORT CassError
cass_data_type_sub_type_name(const CassDataType* data_type,
                             size_t index,
                             const char** name,
                             size_t* name_length);

/**
 * Adds a sub-data type to a tuple or collection.
 *
 * <b>Note:</b> Only valid for tuple and collection data types.
 *
 * @param[in] data_type
 * @param[in] sub_data_type
 * @return CASS_OK if successful, otherwise an error occurred.
 */
CASS_EXPORT CassError
cass_data_type_add_sub_type(CassDataType* data_type,
                            const CassDataType* sub_data_type);

/**
 * Adds a sub-data type to a UDT (user defined type).
 *
 * <b>Note:</b> Only valid for UDT data types.
 *
 * @cassandra{2.1+}
 *
 * @param[in] data_type
 * @param[in] name
 * @param[in] sub_data_type
 * @return CASS_OK if successful, otherwise an error occurred.
 */
CASS_EXPORT CassError
cass_data_type_add_sub_type_by_name(CassDataType* data_type,
                                    const char* name,
                                    const CassDataType* sub_data_type);

/**
 * Same as cass_data_type_add_sub_type_by_name(), but with lengths for string
 * parameters.
 *
 * <b>Note:</b> Only valid for UDT data types.
 *
 * @cassandra{2.1+}
 *
 * @param[in] data_type
 * @param[in] name
 * @param[in] name_length
 * @param[in] sub_data_type
 * @return CASS_OK if successful, otherwise an error occurred.
 */
CASS_EXPORT CassError
cass_data_type_add_sub_type_by_name_n(CassDataType* data_type,
                                      const char* name,
                                      size_t name_length,
                                      const CassDataType* sub_data_type);

/**
 * Adds a sub-data type to a tuple or collection using a value type.
 *
 * <b>Note:</b> Only valid for tuple and collection data types.
 *
 * @param[in] data_type
 * @param[in] sub_value_type
 * @return CASS_OK if successful, otherwise an error occurred.
 */
CASS_EXPORT CassError
cass_data_type_add_sub_value_type(CassDataType* data_type,
                                  CassValueType sub_value_type);


/**
 * Adds a sub-data type to a UDT (user defined type) using a value type.
 *
 * <b>Note:</b> Only valid for UDT data types.
 *
 * @cassandra{2.1+}
 *
 * @param[in] data_type
 * @param[in] name
 * @param[in] sub_value_type
 * @return CASS_OK if successful, otherwise an error occurred.
 */
CASS_EXPORT CassError
cass_data_type_add_sub_value_type_by_name(CassDataType* data_type,
                                          const char* name,
                                          CassValueType sub_value_type);

/**
 * Same as cass_data_type_add_sub_value_type_by_name(), but with lengths for string
 * parameters.
 *
 * <b>Note:</b> Only valid for UDT data types.
 *
 * @cassandra{2.1+}
 *
 * @param[in] data_type
 * @param[in] name
 * @param[in] name_length
 * @param[in] sub_value_type
 * @return CASS_OK if successful, otherwise an error occurred.
 */
CASS_EXPORT CassError
cass_data_type_add_sub_value_type_by_name_n(CassDataType* data_type,
                                            const char* name,
                                            size_t name_length,
                                            CassValueType sub_value_type);

/***********************************************************************************
 *
 * Collection
 *
 ***********************************************************************************/

/**
 * Creates a new collection.
 *
 * @public @memberof CassCollection
 *
 * @param[in] type
 * @param[in] item_count The approximate number of items in the collection.
 * @return Returns a collection that must be freed.
 *
 * @see cass_collection_free()
 */
CASS_EXPORT CassCollection*
cass_collection_new(CassCollectionType type,
                    size_t item_count);

/**
 * Creates a new collection from an existing data type.
 *
 * @public @memberof CassCollection
 *
 * @param[in] data_type
 * @param[in] item_count The approximate number of items in the collection.
 * @return Returns a collection that must be freed.
 *
 * @see cass_collection_free();
 */
CASS_EXPORT CassCollection*
cass_collection_new_from_data_type(const CassDataType* data_type,
                                   size_t item_count);

/**
 * Frees a collection instance.
 *
 * @public @memberof CassCollection
 *
 * @param[in] collection
 */
CASS_EXPORT void
cass_collection_free(CassCollection* collection);

/**
 * Gets the data type of a collection.
 *
 * @param[in] collection
 * @return Returns a reference to the data type of the collection. Do not free
 * this reference as it is bound to the lifetime of the collection.
 */
CASS_EXPORT const CassDataType*
cass_collection_data_type(const CassCollection* collection);

/**
 * Appends a "tinyint" to the collection.
 *
 * @cassandra{2.2+}
 *
 * @public @memberof CassCollection
 *
 * @param[in] collection
 * @param[in] value
 * @return CASS_OK if successful, otherwise an error occurred.
 */
CASS_EXPORT CassError
cass_collection_append_int8(CassCollection* collection,
                            cass_int8_t value);

/**
 * Appends an "smallint" to the collection.
 *
 * @cassandra{2.2+}
 *
 * @public @memberof CassCollection
 *
 * @param[in] collection
 * @param[in] value
 * @return CASS_OK if successful, otherwise an error occurred.
 */
CASS_EXPORT CassError
cass_collection_append_int16(CassCollection* collection,
                             cass_int16_t value);

/**
 * Appends an "int" to the collection.
 *
 * @public @memberof CassCollection
 *
 * @param[in] collection
 * @param[in] value
 * @return CASS_OK if successful, otherwise an error occurred.
 */
CASS_EXPORT CassError
cass_collection_append_int32(CassCollection* collection,
                             cass_int32_t value);

/**
 * Appends a "date" to the collection.
 *
 * @cassandra{2.2+}
 *
 * @public @memberof CassCollection
 *
 * @param[in] collection
 * @param[in] value
 * @return CASS_OK if successful, otherwise an error occurred.
 */
CASS_EXPORT CassError
cass_collection_append_uint32(CassCollection* collection,
                              cass_uint32_t value);


/**
 * Appends a "bigint", "counter", "timestamp" or "time" to the
 * collection.
 *
 * @public @memberof CassCollection
 *
 * @param[in] collection
 * @param[in] value
 * @return CASS_OK if successful, otherwise an error occurred.
 */
CASS_EXPORT CassError
cass_collection_append_int64(CassCollection* collection,
                             cass_int64_t value);

/**
 * Appends a "float" to the collection.
 *
 * @public @memberof CassCollection
 *
 * @param[in] collection
 * @param[in] value
 * @return CASS_OK if successful, otherwise an error occurred.
 */
CASS_EXPORT CassError
cass_collection_append_float(CassCollection* collection,
                             cass_float_t value);

/**
 * Appends a "double" to the collection.
 *
 * @public @memberof CassCollection
 *
 * @param[in] collection
 * @param[in] value
 * @return CASS_OK if successful, otherwise an error occurred.
 */
CASS_EXPORT CassError
cass_collection_append_double(CassCollection* collection,
                              cass_double_t value);

/**
 * Appends a "boolean" to the collection.
 *
 * @public @memberof CassCollection
 *
 * @param[in] collection
 * @param[in] value
 * @return CASS_OK if successful, otherwise an error occurred.
 */
CASS_EXPORT CassError
cass_collection_append_bool(CassCollection* collection,
                            cass_bool_t value);

/**
 * Appends an "ascii", "text" or "varchar" to the collection.
 *
 * @public @memberof CassCollection
 *
 * @param[in] collection
 * @param[in] value The value is copied into the collection object; the
 * memory pointed to by this parameter can be freed after this call.
 * @return CASS_OK if successful, otherwise an error occurred.
 */
CASS_EXPORT CassError
cass_collection_append_string(CassCollection* collection,
                              const char* value);


/**
 * Same as cass_collection_append_string(), but with lengths for string
 * parameters.
 *
 * @public @memberof CassCollection
 *
 * @param[in] collection
 * @param[in] value
 * @param[in] value_length
 * @return same as cass_collection_append_string()
 *
 * @see cass_collection_append_string();
 */
CASS_EXPORT CassError
cass_collection_append_string_n(CassCollection* collection,
                                const char* value,
                                size_t value_length);

/**
 * Appends a "blob", "varint" or "custom" to the collection.
 *
 * @public @memberof CassCollection
 *
 * @param[in] collection
 * @param[in] value The value is copied into the collection object; the
 * memory pointed to by this parameter can be freed after this call.
 * @param[in] value_size
 * @return CASS_OK if successful, otherwise an error occurred.
 */
CASS_EXPORT CassError
cass_collection_append_bytes(CassCollection* collection,
                             const cass_byte_t* value,
                             size_t value_size);

/**
 * Appends a "custom" to the collection.
 *
 * @public @memberof CassCollection
 *
 * @param[in] collection
 * @param[in] class_name
 * @param[in] value The value is copied into the collection object; the
 * memory pointed to by this parameter can be freed after this call.
 * @param[in] value_size
 * @return CASS_OK if successful, otherwise an error occurred.
 */
CASS_EXPORT CassError
cass_collection_append_custom(CassCollection* collection,
                              const char* class_name,
                              const cass_byte_t* value,
                              size_t value_size);

/**
 * Same as cass_collection_append_custom(), but with lengths for string
 * parameters.
 *
 * @public @memberof CassCollection
 *
 * @param[in] collection
 * @param[in] class_name
 * @param[in] class_name_length
 * @param[in] value
 * @param[in] value_size
 * @return same as cass_collection_append_custom()
 *
 * @see cass_collection_append_custom()
 */
CASS_EXPORT CassError
cass_collection_append_custom_n(CassCollection* collection,
                                const char* class_name,
                                size_t class_name_length,
                                const cass_byte_t* value,
                                size_t value_size);

/**
 * Appends a "uuid" or "timeuuid"  to the collection.
 *
 * @public @memberof CassCollection
 *
 * @param[in] collection
 * @param[in] value
 * @return CASS_OK if successful, otherwise an error occurred.
 */
CASS_EXPORT CassError
cass_collection_append_uuid(CassCollection* collection,
                            CassUuid value);

/**
 * Appends an "inet" to the collection.
 *
 * @public @memberof CassCollection
 *
 * @param[in] collection
 * @param[in] value
 * @return CASS_OK if successful, otherwise an error occurred.
 */
CASS_EXPORT CassError
cass_collection_append_inet(CassCollection* collection,
                            CassInet value);

/**
 * Appends a "decimal" to the collection.
 *
 * @public @memberof CassCollection
 *
 * @param[in] collection
 * @param[in] varint The value is copied into the collection object; the
 * memory pointed to by this parameter can be freed after this call.
 * @param[in] varint_size
 * @param[in] scale
 * @return CASS_OK if successful, otherwise an error occurred.
 */
CASS_EXPORT CassError
cass_collection_append_decimal(CassCollection* collection,
                               const cass_byte_t* varint,
                               size_t varint_size,
                               cass_int32_t scale);

/**
 * Appends a "duration" to the collection.
 *
 * @cassandra{3.10+}
 *
 * @public @memberof CassCollection
 *
 * @param[in] collection
 * @param[in] months
 * @param[in] days
 * @param[in] nanos
 * @return CASS_OK if successful, otherwise an error occurred.
 */
CASS_EXPORT CassError
cass_collection_append_duration(CassCollection* collection,
                                cass_int32_t months,
                                cass_int32_t days,
                                cass_int64_t nanos);

/**
 * Appends a "list", "map" or "set" to the collection.
 *
 * @cassandra{2.1+}
 *
 * @public @memberof CassCollection
 *
 * @param[in] collection
 * @param[in] value
 * @return CASS_OK if successful, otherwise an error occurred.
 */
CASS_EXPORT CassError
cass_collection_append_collection(CassCollection* collection,
                                  const CassCollection* value);

/**
 * Appends a "tuple" to the collection.
 *
 * @cassandra{2.1+}
 *
 * @public @memberof CassCollection
 *
 * @param[in] collection
 * @param[in] value
 * @return CASS_OK if successful, otherwise an error occurred.
 */
CASS_EXPORT CassError
cass_collection_append_tuple(CassCollection* collection,
                             const CassTuple* value);

/**
 * Appends a "udt" to the collection.
 *
 * @cassandra{2.1+}
 *
 * @public @memberof CassCollection
 *
 * @param[in] collection
 * @param[in] value
 * @return CASS_OK if successful, otherwise an error occurred.
 */
CASS_EXPORT CassError
cass_collection_append_user_type(CassCollection* collection,
                                 const CassUserType* value);

/***********************************************************************************
 *
 * Tuple
 *
 ***********************************************************************************/

/**
 * Creates a new tuple.
 *
 * @cassandra{2.1+}
 *
 * @public @memberof CassTuple
 *
 * @param[in] item_count The number of items in the tuple.
 * @return Returns a tuple that must be freed.
 *
 * @see cass_tuple_free()
 */
CASS_EXPORT CassTuple*
cass_tuple_new(size_t item_count);

/**
 * Creates a new tuple from an existing data type.
 *
 * @cassandra{2.1+}
 *
 * @public @memberof CassTuple
 *
 * @param[in] data_type
 * @return Returns a tuple that must be freed.
 *
 * @see cass_tuple_free();
 */
CASS_EXPORT CassTuple*
cass_tuple_new_from_data_type(const CassDataType* data_type);

/**
 * Frees a tuple instance.
 *
 * @cassandra{2.1+}
 *
 * @public @memberof CassTuple
 *
 * @param[in] tuple
 */
CASS_EXPORT void
cass_tuple_free(CassTuple* tuple);

/**
 * Gets the data type of a tuple.
 *
 * @cassandra{2.1+}
 *
 * @param[in] tuple
 * @return Returns a reference to the data type of the tuple. Do not free
 * this reference as it is bound to the lifetime of the tuple.
 */
CASS_EXPORT const CassDataType*
cass_tuple_data_type(const CassTuple* tuple);

/**
 * Sets an null in a tuple at the specified index.
 *
 * @cassandra{2.1+}
 *
 * @public @memberof CassTuple
 *
 * @param[in] tuple
 * @param[in] index
 * @return CASS_OK if successful, otherwise an error occurred.
 */
CASS_EXPORT CassError
cass_tuple_set_null(CassTuple* tuple, size_t index);

/**
 * Sets a "tinyint" in a tuple at the specified index.
 *
 * @cassandra{2.2+}
 *
 * @public @memberof CassTuple
 *
 * @param[in] tuple
 * @param[in] index
 * @param[in] value
 * @return CASS_OK if successful, otherwise an error occurred.
 */
CASS_EXPORT CassError
cass_tuple_set_int8(CassTuple* tuple,
                    size_t index,
                    cass_int8_t value);

/**
 * Sets an "smallint" in a tuple at the specified index.
 *
 * @cassandra{2.2+}
 *
 * @public @memberof CassTuple
 *
 * @param[in] tuple
 * @param[in] index
 * @param[in] value
 * @return CASS_OK if successful, otherwise an error occurred.
 */
CASS_EXPORT CassError
cass_tuple_set_int16(CassTuple* tuple,
                     size_t index,
                     cass_int16_t value);

/**
 * Sets an "int" in a tuple at the specified index.
 *
 * @cassandra{2.1+}
 *
 * @public @memberof CassTuple
 *
 * @param[in] tuple
 * @param[in] index
 * @param[in] value
 * @return CASS_OK if successful, otherwise an error occurred.
 */
CASS_EXPORT CassError
cass_tuple_set_int32(CassTuple* tuple,
                     size_t index,
                     cass_int32_t value);

/**
 * Sets a "date" in a tuple at the specified index.
 *
 * @cassandra{2.2+}
 *
 * @public @memberof CassTuple
 *
 * @param[in] tuple
 * @param[in] index
 * @param[in] value
 * @return CASS_OK if successful, otherwise an error occurred.
 */
CASS_EXPORT CassError
cass_tuple_set_uint32(CassTuple* tuple,
                      size_t index,
                      cass_uint32_t value);

/**
 * Sets a "bigint", "counter", "timestamp" or "time" in a tuple at the
 * specified index.
 *
 * @cassandra{2.1+}
 *
 * @public @memberof CassTuple
 *
 * @param[in] tuple
 * @param[in] index
 * @param[in] value
 * @return CASS_OK if successful, otherwise an error occurred.
 */
CASS_EXPORT CassError
cass_tuple_set_int64(CassTuple* tuple,
                     size_t index,
                     cass_int64_t value);

/**
 * Sets a "float" in a tuple at the specified index.
 *
 * @cassandra{2.1+}
 *
 * @public @memberof CassTuple
 *
 * @param[in] tuple
 * @param[in] index
 * @param[in] value
 * @return CASS_OK if successful, otherwise an error occurred.
 */
CASS_EXPORT CassError
cass_tuple_set_float(CassTuple* tuple,
                     size_t index,
                     cass_float_t value);

/**
 * Sets a "double" in a tuple at the specified index.
 *
 * @cassandra{2.1+}
 *
 * @public @memberof CassTuple
 *
 * @param[in] tuple
 * @param[in] index
 * @param[in] value
 * @return CASS_OK if successful, otherwise an error occurred.
 */
CASS_EXPORT CassError
cass_tuple_set_double(CassTuple* tuple,
                      size_t index,
                      cass_double_t value);

/**
 * Sets a "boolean" in a tuple at the specified index.
 *
 * @cassandra{2.1+}
 *
 * @public @memberof CassTuple
 *
 * @param[in] tuple
 * @param[in] index
 * @param[in] value
 * @return CASS_OK if successful, otherwise an error occurred.
 */
CASS_EXPORT CassError
cass_tuple_set_bool(CassTuple* tuple,
                    size_t index,
                    cass_bool_t value);

/**
 * Sets an "ascii", "text" or "varchar" in a tuple at the specified index.
 *
 * @cassandra{2.1+}
 *
 * @public @memberof CassTuple
 *
 * @param[in] tuple
 * @param[in] index
 * @param[in] value The value is copied into the tuple object; the
 * memory pointed to by this parameter can be freed after this call.
 * @return CASS_OK if successful, otherwise an error occurred.
 */
CASS_EXPORT CassError
cass_tuple_set_string(CassTuple* tuple,
                      size_t index,
                      const char* value);

/**
 * Same as cass_tuple_set_string(), but with lengths for string
 * parameters.
 *
 * @cassandra{2.1+}
 *
 * @public @memberof CassTuple
 *
 * @param[in] tuple
 * @param[in] index
 * @param[in] value
 * @param[in] value_length
 * @return same as cass_tuple_set_string()
 *
 * @see cass_tuple_set_string();
 */
CASS_EXPORT CassError
cass_tuple_set_string_n(CassTuple* tuple,
                        size_t index,
                        const char* value,
                        size_t value_length);

/**
 * Sets a "blob", "varint" or "custom" in a tuple at the specified index.
 *
 * @cassandra{2.1+}
 *
 * @public @memberof CassTuple
 *
 * @param[in] tuple
 * @param[in] index
 * @param[in] value The value is copied into the tuple object; the
 * memory pointed to by this parameter can be freed after this call.
 * @param[in] value_size
 * @return CASS_OK if successful, otherwise an error occurred.
 */
CASS_EXPORT CassError
cass_tuple_set_bytes(CassTuple* tuple,
                     size_t index,
                     const cass_byte_t* value,
                     size_t value_size);

/**
 * Sets a "custom" in a tuple at the specified index.
 *
 * @public @memberof CassTuple
 *
 * @param[in] tuple
 * @param[in] index
 * @param[in] class_name
 * @param[in] value The value is copied into the tuple object; the
 * memory pointed to by this parameter can be freed after this call.
 * @param[in] value_size
 * @return CASS_OK if successful, otherwise an error occurred.
 */
CASS_EXPORT CassError
cass_tuple_set_custom(CassTuple* tuple,
                      size_t index,
                      const char* class_name,
                      const cass_byte_t* value,
                      size_t value_size);

/**
 * Same as cass_tuple_set_custom(), but with lengths for string
 * parameters.
 *
 * @public @memberof CassTuple
 *
 * @param[in] tuple
 * @param[in] index
 * @param[in] class_name
 * @param[in] class_name_length
 * @param[in] value
 * @param[in] value_size
 * @return same as cass_tuple_set_custom()
 *
 * @see cass_tuple_set_custom()
 */
CASS_EXPORT CassError
cass_tuple_set_custom_n(CassTuple* tuple,
                        size_t index,
                        const char* class_name,
                        size_t class_name_length,
                        const cass_byte_t* value,
                        size_t value_size);

/**
 * Sets a "uuid" or "timeuuid" in a tuple at the specified index.
 *
 * @cassandra{2.1+}
 *
 * @public @memberof CassTuple
 *
 * @param[in] tuple
 * @param[in] index
 * @param[in] value
 * @return CASS_OK if successful, otherwise an error occurred.
 */
CASS_EXPORT CassError
cass_tuple_set_uuid(CassTuple* tuple,
                    size_t index,
                    CassUuid value);

/**
 * Sets an "inet" in a tuple at the specified index.
 *
 * @cassandra{2.1+}
 *
 * @public @memberof CassTuple
 *
 * @param[in] tuple
 * @param[in] index
 * @param[in] value
 * @return CASS_OK if successful, otherwise an error occurred.
 */
CASS_EXPORT CassError
cass_tuple_set_inet(CassTuple* tuple,
                    size_t index,
                    CassInet value);

/**
 * Sets a "decimal" in a tuple at the specified index.
 *
 * @cassandra{2.1+}
 *
 * @public @memberof CassTuple
 *
 * @param[in] tuple
 * @param[in] index
 * @param[in] varint The value is copied into the tuple object; the
 * memory pointed to by this parameter can be freed after this call.
 * @param[in] varint_size
 * @param[in] scale
 * @return CASS_OK if successful, otherwise an error occurred.
 */
CASS_EXPORT CassError
cass_tuple_set_decimal(CassTuple* tuple,
                       size_t index,
                       const cass_byte_t* varint,
                       size_t varint_size,
                       cass_int32_t scale);

/**
 * Sets a "duration" in a tuple at the specified index.
 *
 * @cassandra{3.10+}
 *
 * @public @memberof CassTuple
 *
 * @param[in] tuple
 * @param[in] index
 * @param[in] months
 * @param[in] days
 * @param[in] nanos
 * @return CASS_OK if successful, otherwise an error occurred.
 */
CASS_EXPORT CassError
cass_tuple_set_duration(CassTuple* tuple,
                        size_t index,
                        cass_int32_t months,
                        cass_int32_t days,
                        cass_int64_t nanos);

/**
 * Sets a "list", "map" or "set" in a tuple at the specified index.
 *
 * @cassandra{2.1+}
 *
 * @public @memberof CassTuple
 *
 * @param[in] tuple
 * @param[in] index
 * @param[in] value
 * @return CASS_OK if successful, otherwise an error occurred.
 */
CASS_EXPORT CassError
cass_tuple_set_collection(CassTuple* tuple,
                          size_t index,
                          const CassCollection* value);

/**
 * Sets a "tuple" in a tuple at the specified index.
 *
 * @cassandra{2.1+}
 *
 * @public @memberof CassTuple
 *
 * @param[in] tuple
 * @param[in] index
 * @param[in] value
 * @return CASS_OK if successful, otherwise an error occurred.
 */
CASS_EXPORT CassError
cass_tuple_set_tuple(CassTuple* tuple,
                     size_t index,
                     const CassTuple* value);

/**
 * Sets a "udt" in a tuple at the specified index.
 *
 * @cassandra{2.1+}
 *
 * @public @memberof CassTuple
 *
 * @param[in] tuple
 * @param[in] index
 * @param[in] value
 * @return CASS_OK if successful, otherwise an error occurred.
 */
CASS_EXPORT CassError
cass_tuple_set_user_type(CassTuple* tuple,
                         size_t index,
                         const CassUserType* value);

/***********************************************************************************
 *
 * User defined type
 *
 ***********************************************************************************/

/**
 * Creates a new user defined type from existing data type;
 *
 * @cassandra{2.1+}
 *
 * @public @memberof CassUserType
 *
 * @param[in] data_type
 * @return Returns a user defined type that must be freed. NULL is returned if
 * the data type is not a user defined type.
 *
 * @see cass_user_type_free()
 */
CASS_EXPORT CassUserType*
cass_user_type_new_from_data_type(const CassDataType* data_type);

/**
 * Frees a user defined type instance.
 *
 * @cassandra{2.1+}
 *
 * @public @memberof CassUserType
 *
 * @param[in] user_type
 */
CASS_EXPORT void
cass_user_type_free(CassUserType* user_type);

/**
 * Gets the data type of a user defined type.
 *
 * @cassandra{2.1+}
 *
 * @param[in] user_type
 * @return Returns a reference to the data type of the user defined type.
 * Do not free this reference as it is bound to the lifetime of the
 * user defined type.
 */
CASS_EXPORT const CassDataType*
cass_user_type_data_type(const CassUserType* user_type);

/**
 * Sets a null in a user defined type at the specified index.
 *
 * @cassandra{2.1+}
 *
 * @public @memberof CassUserType
 *
 * @param[in] user_type
 * @param[in] index
 * @return CASS_OK if successful, otherwise an error occurred.
 */
CASS_EXPORT CassError
cass_user_type_set_null(CassUserType* user_type,
                        size_t index);

/**
 * Sets a null in a user defined type at the specified name.
 *
 * @cassandra{2.1+}
 *
 * @public @memberof CassUserType
 *
 * @param[in] user_type
 * @param[in] name
 * @return CASS_OK if successful, otherwise an error occurred.
 */
CASS_EXPORT CassError
cass_user_type_set_null_by_name(CassUserType* user_type,
                                const char* name);

/**
 * Same as cass_user_type_set_null_by_name(), but with lengths for string
 * parameters.
 *
 * @cassandra{2.1+}
 *
 * @public @memberof CassUserType
 *
 * @param[in] user_type
 * @param[in] name
 * @param[in] name_length
 * @return same as cass_user_type_set_null_by_name()
 *
 * @see cass_user_type_set_null_by_name()
 */
CASS_EXPORT CassError
cass_user_type_set_null_by_name_n(CassUserType* user_type,
                                   const char* name,
                                   size_t name_length);

/**
 * Sets a "tinyint" in a user defined type at the specified index.
 *
 * @cassandra{2.2+}
 *
 * @public @memberof CassUserType
 *
 * @param[in] user_type
 * @param[in] index
 * @param[in] value
 * @return CASS_OK if successful, otherwise an error occurred.
 */
CASS_EXPORT CassError
cass_user_type_set_int8(CassUserType* user_type,
                        size_t index,
                        cass_int8_t value);

/**
 * Sets a "tinyint" in a user defined type at the specified name.
 *
 * @cassandra{2.2+}
 *
 * @public @memberof CassUserType
 *
 * @param[in] user_type
 * @param[in] name
 * @param[in] value
 * @return CASS_OK if successful, otherwise an error occurred.
 */
CASS_EXPORT CassError
cass_user_type_set_int8_by_name(CassUserType* user_type,
                                const char* name,
                                cass_int8_t value);

/**
 * Same as cass_user_type_set_int8_by_name(), but with lengths for string
 * parameters.
 *
 * @cassandra{2.2+}
 *
 * @public @memberof CassUserType
 *
 * @param[in] user_type
 * @param[in] name
 * @param[in] name_length
 * @param[in] value
 * @return same as cass_user_type_set_int8_by_name()
 *
 * @see cass_user_type_set_int8_by_name()
 */
CASS_EXPORT CassError
cass_user_type_set_int8_by_name_n(CassUserType* user_type,
                                  const char* name,
                                  size_t name_length,
                                  cass_int8_t value);

/**
 * Sets an "smallint" in a user defined type at the specified index.
 *
 * @cassandra{2.2+}
 *
 * @public @memberof CassUserType
 *
 * @param[in] user_type
 * @param[in] index
 * @param[in] value
 * @return CASS_OK if successful, otherwise an error occurred.
 */
CASS_EXPORT CassError
cass_user_type_set_int16(CassUserType* user_type,
                         size_t index,
                         cass_int16_t value);

/**
 * Sets an "smallint" in a user defined type at the specified name.
 *
 * @cassandra{2.2+}
 *
 * @public @memberof CassUserType
 *
 * @param[in] user_type
 * @param[in] name
 * @param[in] value
 * @return CASS_OK if successful, otherwise an error occurred.
 */
CASS_EXPORT CassError
cass_user_type_set_int16_by_name(CassUserType* user_type,
                                 const char* name,
                                 cass_int16_t value);

/**
 * Same as cass_user_type_set_int16_by_name(), but with lengths for string
 * parameters.
 *
 * @cassandra{2.2+}
 *
 * @public @memberof CassUserType
 *
 * @param[in] user_type
 * @param[in] name
 * @param[in] name_length
 * @param[in] value
 * @return same as cass_user_type_set_int16_by_name()
 *
 * @see cass_user_type_set_int16_by_name()
 */
CASS_EXPORT CassError
cass_user_type_set_int16_by_name_n(CassUserType* user_type,
                                   const char* name,
                                   size_t name_length,
                                   cass_int16_t value);

/**
 * Sets an "int" in a user defined type at the specified index.
 *
 * @cassandra{2.1+}
 *
 * @public @memberof CassUserType
 *
 * @param[in] user_type
 * @param[in] index
 * @param[in] value
 * @return CASS_OK if successful, otherwise an error occurred.
 */
CASS_EXPORT CassError
cass_user_type_set_int32(CassUserType* user_type,
                         size_t index,
                         cass_int32_t value);

/**
 * Sets an "int" in a user defined type at the specified name.
 *
 * @cassandra{2.1+}
 *
 * @public @memberof CassUserType
 *
 * @param[in] user_type
 * @param[in] name
 * @param[in] value
 * @return CASS_OK if successful, otherwise an error occurred.
 */
CASS_EXPORT CassError
cass_user_type_set_int32_by_name(CassUserType* user_type,
                                 const char* name,
                                 cass_int32_t value);

/**
 * Same as cass_user_type_set_int32_by_name(), but with lengths for string
 * parameters.
 *
 * @cassandra{2.1+}
 *
 * @public @memberof CassUserType
 *
 * @param[in] user_type
 * @param[in] name
 * @param[in] name_length
 * @param[in] value
 * @return same as cass_user_type_set_int32_by_name()
 *
 * @see cass_user_type_set_int32_by_name()
 */
CASS_EXPORT CassError
cass_user_type_set_int32_by_name_n(CassUserType* user_type,
                                   const char* name,
                                   size_t name_length,
                                   cass_int32_t value);

/**
 * Sets a "date" in a user defined type at the specified index.
 *
 * @cassandra{2.2+}
 *
 * @public @memberof CassUserType
 *
 * @param[in] user_type
 * @param[in] index
 * @param[in] value
 * @return CASS_OK if successful, otherwise an error occurred.
 */
CASS_EXPORT CassError
cass_user_type_set_uint32(CassUserType* user_type,
                          size_t index,
                          cass_uint32_t value);

/**
 * Sets a "date" in a user defined type at the specified name.
 *
 * @cassandra{2.2+}
 *
 * @public @memberof CassUserType
 *
 * @param[in] user_type
 * @param[in] name
 * @param[in] value
 * @return CASS_OK if successful, otherwise an error occurred.
 */
CASS_EXPORT CassError
cass_user_type_set_uint32_by_name(CassUserType* user_type,
                                  const char* name,
                                  cass_uint32_t value);

/**
 * Same as cass_user_type_set_uint32_by_name(), but with lengths for string
 * parameters.
 *
 * @cassandra{2.2+}
 *
 * @public @memberof CassUserType
 *
 * @param[in] user_type
 * @param[in] name
 * @param[in] name_length
 * @param[in] value
 * @return same as cass_user_type_set_uint32_by_name()
 *
 * @see cass_user_type_set_uint32_by_name()
 */
CASS_EXPORT CassError
cass_user_type_set_uint32_by_name_n(CassUserType* user_type,
                                    const char* name,
                                    size_t name_length,
                                    cass_uint32_t value);


/**
 * Sets an "bigint", "counter", "timestamp" or "time" in a
 * user defined type at the specified index.
 *
 * @cassandra{2.1+}
 *
 * @public @memberof CassUserType
 *
 * @param[in] user_type
 * @param[in] index
 * @param[in] value
 * @return CASS_OK if successful, otherwise an error occurred.
 */
CASS_EXPORT CassError
cass_user_type_set_int64(CassUserType* user_type,
                         size_t index,
                         cass_int64_t value);

/**
 * Sets an "bigint", "counter", "timestamp" or "time" in a
 * user defined type at the specified name.
 *
 * @cassandra{2.1+}
 *
 * @public @memberof CassUserType
 *
 * @param[in] user_type
 * @param[in] name
 * @param[in] value
 * @return CASS_OK if successful, otherwise an error occurred.
 */
CASS_EXPORT CassError
cass_user_type_set_int64_by_name(CassUserType* user_type,
                                 const char* name,
                                 cass_int64_t value);

/**
 * Same as cass_user_type_set_int64_by_name(), but with lengths for string
 * parameters.
 *
 * @cassandra{2.1+}
 *
 * @public @memberof CassUserType
 *
 * @param[in] user_type
 * @param[in] name
 * @param[in] name_length
 * @param[in] value
 * @return same as cass_user_type_set_int64_by_name()
 *
 * @see cass_user_type_set_int64_by_name()
 */
CASS_EXPORT CassError
cass_user_type_set_int64_by_name_n(CassUserType* user_type,
                                   const char* name,
                                   size_t name_length,
                                   cass_int64_t value);

/**
 * Sets a "float" in a user defined type at the specified index.
 *
 * @cassandra{2.1+}
 *
 * @public @memberof CassUserType
 *
 * @param[in] user_type
 * @param[in] index
 * @param[in] value
 * @return CASS_OK if successful, otherwise an error occurred.
 */
CASS_EXPORT CassError
cass_user_type_set_float(CassUserType* user_type,
                         size_t index,
                         cass_float_t value);

/**
 * Sets a "float" in a user defined type at the specified name.
 *
 * @cassandra{2.1+}
 *
 * @public @memberof CassUserType
 *
 * @param[in] user_type
 * @param[in] name
 * @param[in] value
 * @return CASS_OK if successful, otherwise an error occurred.
 */
CASS_EXPORT CassError
cass_user_type_set_float_by_name(CassUserType* user_type,
                                 const char* name,
                                 cass_float_t value);

/**
 * Same as cass_user_type_set_float_by_name(), but with lengths for string
 * parameters.
 *
 * @cassandra{2.1+}
 *
 * @public @memberof CassUserType
 *
 * @param[in] user_type
 * @param[in] name
 * @param[in] name_length
 * @param[in] value
 * @return same as cass_user_type_set_float_by_name()
 *
 * @see cass_user_type_set_float_by_name()
 */
CASS_EXPORT CassError
cass_user_type_set_float_by_name_n(CassUserType* user_type,
                                   const char* name,
                                   size_t name_length,
                                   cass_float_t value);

/**
 * Sets an "double" in a user defined type at the specified index.
 *
 * @cassandra{2.1+}
 *
 * @public @memberof CassUserType
 *
 * @param[in] user_type
 * @param[in] index
 * @param[in] value
 * @return CASS_OK if successful, otherwise an error occurred.
 */
CASS_EXPORT CassError
cass_user_type_set_double(CassUserType* user_type,
                         size_t index,
                         cass_double_t value);

/**
 * Sets an "double" in a user defined type at the specified name.
 *
 * @cassandra{2.1+}
 *
 * @public @memberof CassUserType
 *
 * @param[in] user_type
 * @param[in] name
 * @param[in] value
 * @return CASS_OK if successful, otherwise an error occurred.
 */
CASS_EXPORT CassError
cass_user_type_set_double_by_name(CassUserType* user_type,
                                 const char* name,
                                 cass_double_t value);

/**
 * Same as cass_user_type_set_double_by_name(), but with lengths for string
 * parameters.
 *
 * @cassandra{2.1+}
 *
 * @public @memberof CassUserType
 *
 * @param[in] user_type
 * @param[in] name
 * @param[in] name_length
 * @param[in] value
 * @return same as cass_user_type_set_double_by_name()
 *
 * @see cass_user_type_set_double_by_name()
 */
CASS_EXPORT CassError
cass_user_type_set_double_by_name_n(CassUserType* user_type,
                                   const char* name,
                                   size_t name_length,
                                   cass_double_t value);

/**
 * Sets a "boolean" in a user defined type at the specified index.
 *
 * @cassandra{2.1+}
 *
 * @public @memberof CassUserType
 *
 * @param[in] user_type
 * @param[in] index
 * @param[in] value
 * @return CASS_OK if successful, otherwise an error occurred.
 */
CASS_EXPORT CassError
cass_user_type_set_bool(CassUserType* user_type,
                         size_t index,
                         cass_bool_t value);

/**
 * Sets a "boolean" in a user defined type at the specified name.
 *
 * @cassandra{2.1+}
 *
 * @public @memberof CassUserType
 *
 * @param[in] user_type
 * @param[in] name
 * @param[in] value
 * @return CASS_OK if successful, otherwise an error occurred.
 */
CASS_EXPORT CassError
cass_user_type_set_bool_by_name(CassUserType* user_type,
                                 const char* name,
                                 cass_bool_t value);

/**
 * Same as cass_user_type_set_double_by_name(), but with lengths for string
 * parameters.
 *
 * @cassandra{2.1+}
 *
 * @public @memberof CassUserType
 *
 * @param[in] user_type
 * @param[in] name
 * @param[in] name_length
 * @param[in] value
 * @return same as cass_user_type_set_double_by_name()
 *
 * @see cass_user_type_set_double_by_name()
 */
CASS_EXPORT CassError
cass_user_type_set_bool_by_name_n(CassUserType* user_type,
                                   const char* name,
                                   size_t name_length,
                                   cass_bool_t value);


/**
 * Sets an "ascii", "text" or "varchar" in a user defined type at the
 * specified index.
 *
 * @cassandra{2.1+}
 *
 * @public @memberof CassUserType
 *
 * @param[in] user_type
 * @param[in] index
 * @param[in] value
 * @return CASS_OK if successful, otherwise an error occurred.
 */
CASS_EXPORT CassError
cass_user_type_set_string(CassUserType* user_type,
                          size_t index,
                          const char* value);

/**
 * Same as cass_user_type_set_string(), but with lengths for string
 * parameters.
 *
 * @cassandra{2.1+}
 *
 * @public @memberof CassUserType
 *
 * @param[in] user_type
 * @param[in] index
 * @param[in] value
 * @param[in] value_length
 * @return same as cass_user_type_set_string()
 *
 * @see cass_user_type_set_string()
 */
CASS_EXPORT CassError
cass_user_type_set_string_n(CassUserType* user_type,
                            size_t index,
                            const char* value,
                            size_t value_length);

/**
 * Sets an "ascii", "text" or "varchar" in a user defined type at the
 * specified name.
 *
 * @cassandra{2.1+}
 *
 * @public @memberof CassUserType
 *
 * @param[in] user_type
 * @param[in] name
 * @param[in] value
 * @return CASS_OK if successful, otherwise an error occurred.
 */
CASS_EXPORT CassError
cass_user_type_set_string_by_name(CassUserType* user_type,
                                 const char* name,
                                 const char* value);

/**
 * Same as cass_user_type_set_string_by_name(), but with lengths for string
 * parameters.
 *
 * @cassandra{2.1+}
 *
 * @public @memberof CassUserType
 *
 * @param[in] user_type
 * @param[in] name
 * @param[in] name_length
 * @param[in] value
 * @param[in] value_length
 * @return same as cass_user_type_set_string_by_name()
 *
 * @see cass_user_type_set_string_by_name()
 */
CASS_EXPORT CassError
cass_user_type_set_string_by_name_n(CassUserType* user_type,
                                   const char* name,
                                   size_t name_length,
                                   const char* value,
                                   size_t value_length);

/**
 * Sets a "blob" "varint" or "custom" in a user defined type at the specified index.
 *
 * @cassandra{2.1+}
 *
 * @public @memberof CassUserType
 *
 * @param[in] user_type
 * @param[in] index
 * @param[in] value
 * @param[in] value_size
 * @return CASS_OK if successful, otherwise an error occurred.
 */
CASS_EXPORT CassError
cass_user_type_set_bytes(CassUserType* user_type,
                         size_t index,
                         const cass_byte_t* value,
                         size_t value_size);

/**
 * Sets a "blob", "varint" or "custom" in a user defined type at the specified name.
 *
 * @cassandra{2.1+}
 *
 * @public @memberof CassUserType
 *
 * @param[in] user_type
 * @param[in] name
 * @param[in] value
 * @param[in] value_size
 * @return CASS_OK if successful, otherwise an error occurred.
 */
CASS_EXPORT CassError
cass_user_type_set_bytes_by_name(CassUserType* user_type,
                                 const char* name,
                                 const cass_byte_t* value,
                                 size_t value_size);

/**
 * Same as cass_user_type_set_bytes_by_name(), but with lengths for string
 * parameters.
 *
 * @cassandra{2.1+}
 *
 * @public @memberof CassUserType
 *
 * @param[in] user_type
 * @param[in] name
 * @param[in] name_length
 * @param[in] value
 * @param[in] value_size
 * @return same as cass_user_type_set_bytes_by_name()
 *
 * @see cass_user_type_set_bytes_by_name()
 */
CASS_EXPORT CassError
cass_user_type_set_bytes_by_name_n(CassUserType* user_type,
                                   const char* name,
                                   size_t name_length,
                                   const cass_byte_t* value,
                                   size_t value_size);

/**
 * Sets a "custom" in a user defined type at the specified index.
 *
 * @public @memberof CassUserType
 *
 * @param[in] user_type
 * @param[in] index
 * @param[in] class_name
 * @param[in] value
 * @param[in] value_size
 * @return CASS_OK if successful, otherwise an error occurred.
 */
CASS_EXPORT CassError
cass_user_type_set_custom(CassUserType* user_type,
                          size_t index,
                          const char* class_name,
                          const cass_byte_t* value,
                          size_t value_size);

/**
 * Same as cass_user_type_set_custom(), but with lengths for string
 * parameters.
 *
 * @public @memberof CassUserType
 *
 * @param[in] user_type
 * @param[in] index
 * @param[in] class_name
 * @param[in] class_name_length
 * @param[in] value
 * @param[in] value_size
 * @return same as cass_user_type_set_custom()
 *
 * @see cass_user_type_set_custom()
 */
CASS_EXPORT CassError
cass_user_type_set_custom_n(CassUserType* user_type,
                            size_t index,
                            const char* class_name,
                            size_t class_name_length,
                            const cass_byte_t* value,
                            size_t value_size);

/**
 * Sets a "custom" in a user defined type at the specified name.
 *
 * @public @memberof CassUserType
 *
 * @param[in] user_type
 * @param[in] name
 * @param[in] class_name
 * @param[in] value
 * @param[in] value_size
 * @return CASS_OK if successful, otherwise an error occurred.
 */
CASS_EXPORT CassError
cass_user_type_set_custom_by_name(CassUserType* user_type,
                                  const char* name,
                                  const char* class_name,
                                  const cass_byte_t* value,
                                  size_t value_size);

/**
 * Same as cass_user_type_set_custom_by_name(), but with lengths for string
 * parameters.
 *
 * @public @memberof CassUserType
 *
 * @param[in] user_type
 * @param[in] name
 * @param[in] name_length
 * @param[in] class_name
 * @param[in] class_name_length
 * @param[in] value
 * @param[in] value_size
 * @return same as cass_user_type_set_custom_by_name()
 *
 * @see cass_user_type_set_custom_by_name()
 */
CASS_EXPORT CassError
cass_user_type_set_custom_by_name_n(CassUserType* user_type,
                                    const char* name,
                                    size_t name_length,
                                    const char* class_name,
                                    size_t class_name_length,
                                    const cass_byte_t* value,
                                    size_t value_size);

/**
 * Sets a "uuid" or "timeuuid" in a user defined type at the specified index.
 *
 * @cassandra{2.1+}
 *
 * @public @memberof CassUserType
 *
 * @param[in] user_type
 * @param[in] index
 * @param[in] value
 * @return CASS_OK if successful, otherwise an error occurred.
 */
CASS_EXPORT CassError
cass_user_type_set_uuid(CassUserType* user_type,
                         size_t index,
                         CassUuid value);

/**
 * Sets a "uuid" or "timeuuid" in a user defined type at the specified name.
 *
 * @cassandra{2.1+}
 *
 * @public @memberof CassUserType
 *
 * @param[in] user_type
 * @param[in] name
 * @param[in] value
 * @return CASS_OK if successful, otherwise an error occurred.
 */
CASS_EXPORT CassError
cass_user_type_set_uuid_by_name(CassUserType* user_type,
                                 const char* name,
                                 CassUuid value);

/**
 * Same as cass_user_type_set_uuid_by_name(), but with lengths for string
 * parameters.
 *
 * @cassandra{2.1+}
 *
 * @public @memberof CassUserType
 *
 * @param[in] user_type
 * @param[in] name
 * @param[in] name_length
 * @param[in] value
 * @return same as cass_user_type_set_uuid_by_name()
 *
 * @see cass_user_type_set_uuid_by_name()
 */
CASS_EXPORT CassError
cass_user_type_set_uuid_by_name_n(CassUserType* user_type,
                                   const char* name,
                                   size_t name_length,
                                   CassUuid value);

/**
 * Sets a "inet" in a user defined type at the specified index.
 *
 * @cassandra{2.1+}
 *
 * @public @memberof CassUserType
 *
 * @param[in] user_type
 * @param[in] index
 * @param[in] value
 * @return CASS_OK if successful, otherwise an error occurred.
 */
CASS_EXPORT CassError
cass_user_type_set_inet(CassUserType* user_type,
                         size_t index,
                         CassInet value);

/**
 * Sets a "inet" in a user defined type at the specified name.
 *
 * @cassandra{2.1+}
 *
 * @public @memberof CassUserType
 *
 * @param[in] user_type
 * @param[in] name
 * @param[in] value
 * @return CASS_OK if successful, otherwise an error occurred.
 */
CASS_EXPORT CassError
cass_user_type_set_inet_by_name(CassUserType* user_type,
                                 const char* name,
                                 CassInet value);

/**
 * Same as cass_user_type_set_inet_by_name(), but with lengths for string
 * parameters.
 *
 * @cassandra{2.1+}
 *
 * @public @memberof CassUserType
 *
 * @param[in] user_type
 * @param[in] name
 * @param[in] name_length
 * @param[in] value
 * @return same as cass_user_type_set_inet_by_name()
 *
 * @see cass_user_type_set_inet_by_name()
 */
CASS_EXPORT CassError
cass_user_type_set_inet_by_name_n(CassUserType* user_type,
                                   const char* name,
                                   size_t name_length,
                                   CassInet value);

/**
 * Sets an "decimal" in a user defined type at the specified index.
 *
 * @cassandra{2.1+}
 *
 * @public @memberof CassUserType
 *
 * @param[in] user_type
 * @param[in] index
 * @param[in] varint
 * @param[in] varint_size
 * @param[in] scale
 * @return CASS_OK if successful, otherwise an error occurred.
 */
CASS_EXPORT CassError
cass_user_type_set_decimal(CassUserType* user_type,
                           size_t index,
                           const cass_byte_t* varint,
                           size_t varint_size,
                           int scale);

/**
 * Sets "decimal" in a user defined type at the specified name.
 *
 * @cassandra{2.1+}
 *
 * @public @memberof CassUserType
 *
 * @param[in] user_type
 * @param[in] name
 * @param[in] varint
 * @param[in] varint_size
 * @param[in] scale
 * @return CASS_OK if successful, otherwise an error occurred.
 */
CASS_EXPORT CassError
cass_user_type_set_decimal_by_name(CassUserType* user_type,
                                   const char* name,
                                   const cass_byte_t* varint,
                                   size_t varint_size,
                                   int scale);

/**
 * Same as cass_user_type_set_decimal_by_name(), but with lengths for string
 * parameters.
 *
 * @cassandra{2.1+}
 *
 * @public @memberof CassUserType
 *
 * @param[in] user_type
 * @param[in] name
 * @param[in] name_length
 * @param[in] varint
 * @param[in] varint_size
 * @param[in] scale
 * @return same as cass_user_type_set_decimal_by_name()
 *
 * @see cass_user_type_set_decimal_by_name()
 */
CASS_EXPORT CassError
cass_user_type_set_decimal_by_name_n(CassUserType* user_type,
                                     const char* name,
                                     size_t name_length,
                                     const cass_byte_t* varint,
                                     size_t varint_size,
                                     int scale);

/**
 * Sets a "duration" in a user defined type at the specified index.
 *
 * @cassandra{3.10+}
 *
 * @public @memberof CassUserType
 *
 * @param[in] user_type
 * @param[in] index
 * @param[in] months
 * @param[in] days
 * @param[in] nanos
 * @return CASS_OK if successful, otherwise an error occurred.
 */
CASS_EXPORT CassError
cass_user_type_set_duration(CassUserType* user_type,
                            size_t index,
                            cass_int32_t months,
                            cass_int32_t days,
                            cass_int64_t nanos);

/**
 * Sets "duration" in a user defined type at the specified name.
 *
 * @cassandra{3.10+}
 *
 * @public @memberof CassUserType
 *
 * @param[in] user_type
 * @param[in] name
 * @param[in] months
 * @param[in] days
 * @param[in] nanos
 * @return CASS_OK if successful, otherwise an error occurred.
 */
CASS_EXPORT CassError
cass_user_type_set_duration_by_name(CassUserType* user_type,
                                    const char* name,
                                    cass_int32_t months,
                                    cass_int32_t days,
                                    cass_int64_t nanos);

/**
 * Same as cass_user_type_set_duration_by_name(), but with lengths for string
 * parameters.
 *
 * @cassandra{3.10+}
 *
 * @public @memberof CassUserType
 *
 * @param[in] user_type
 * @param[in] name
 * @param[in] name_length
 * @param[in] months
 * @param[in] days
 * @param[in] nanos
 * @return same as cass_user_type_set_duration_by_name()
 *
 * @see cass_user_type_set_duration_by_name()
 */
CASS_EXPORT CassError
cass_user_type_set_duration_by_name_n(CassUserType* user_type,
                                      const char* name,
                                      size_t name_length,
                                      cass_int32_t months,
                                      cass_int32_t days,
                                      cass_int64_t nanos);

/**
 * Sets a "list", "map" or "set" in a user defined type at the
 * specified index.
 *
 * @cassandra{2.1+}
 *
 * @public @memberof CassUserType
 *
 * @param[in] user_type
 * @param[in] index
 * @param[in] value
 * @return CASS_OK if successful, otherwise an error occurred.
 */
CASS_EXPORT CassError
cass_user_type_set_collection(CassUserType* user_type,
                              size_t index,
                              const CassCollection* value);

/**
 * Sets a "list", "map" or "set" in a user defined type at the
 * specified name.
 *
 * @cassandra{2.1+}
 *
 * @public @memberof CassUserType
 *
 * @param[in] user_type
 * @param[in] name
 * @param[in] value
 * @return CASS_OK if successful, otherwise an error occurred.
 */
CASS_EXPORT CassError
cass_user_type_set_collection_by_name(CassUserType* user_type,
                                      const char* name,
                                      const CassCollection* value);

/**
 * Same as cass_user_type_set_collection_by_name(), but with lengths for string
 * parameters.
 *
 * @cassandra{2.1+}
 *
 * @public @memberof CassUserType
 *
 * @param[in] user_type
 * @param[in] name
 * @param[in] name_length
 * @param[in] value
 * @return same as cass_user_type_set_collection_by_name()
 *
 * @see cass_user_type_set_collection_by_name()
 */
CASS_EXPORT CassError
cass_user_type_set_collection_by_name_n(CassUserType* user_type,
                                        const char* name,
                                        size_t name_length,
                                        const CassCollection* value);

/**
 * Sets a "tuple" in a user defined type at the specified index.
 *
 * @cassandra{2.1+}
 *
 * @public @memberof CassUserType
 *
 * @param[in] user_type
 * @param[in] index
 * @param[in] value
 * @return CASS_OK if successful, otherwise an error occurred.
 */
CASS_EXPORT CassError
cass_user_type_set_tuple(CassUserType* user_type,
                              size_t index,
                              const CassTuple* value);

/**
 * Sets a "tuple" in a user defined type at the specified name.
 *
 * @cassandra{2.1+}
 *
 * @public @memberof CassUserType
 *
 * @param[in] user_type
 * @param[in] name
 * @param[in] value
 * @return CASS_OK if successful, otherwise an error occurred.
 */
CASS_EXPORT CassError
cass_user_type_set_tuple_by_name(CassUserType* user_type,
                                      const char* name,
                                      const CassTuple* value);

/**
 * Same as cass_user_type_set_tuple_by_name(), but with lengths for string
 * parameters.
 *
 * @cassandra{2.1+}
 *
 * @public @memberof CassUserType
 *
 * @param[in] user_type
 * @param[in] name
 * @param[in] name_length
 * @param[in] value
 * @return same as cass_user_type_set_tuple_by_name()
 *
 * @see cass_user_type_set_tuple_by_name()
 */
CASS_EXPORT CassError
cass_user_type_set_tuple_by_name_n(CassUserType* user_type,
                                        const char* name,
                                        size_t name_length,
                                        const CassTuple* value);

/**
 * Sets a user defined type in a user defined type at the specified index.
 *
 * @cassandra{2.1+}
 *
 * @public @memberof CassUserType
 *
 * @param[in] user_type
 * @param[in] index
 * @param[in] value
 * @return CASS_OK if successful, otherwise an error occurred.
 */
CASS_EXPORT CassError
cass_user_type_set_user_type(CassUserType* user_type,
                             size_t index,
                             const CassUserType* value);

/**
 * Sets a user defined type in a user defined type at the specified name.
 *
 * @cassandra{2.1+}
 *
 * @public @memberof CassUserType
 *
 * @param[in] user_type
 * @param[in] name
 * @param[in] value
 * @return CASS_OK if successful, otherwise an error occurred.
 */
CASS_EXPORT CassError
cass_user_type_set_user_type_by_name(CassUserType* user_type,
                                     const char* name,
                                     const CassUserType* value);

/**
 * Same as cass_user_type_set_user_type_by_name(), but with lengths for string
 * parameters.
 *
 * @cassandra{2.1+}
 *
 * @public @memberof CassUserType
 *
 * @param[in] user_type
 * @param[in] name
 * @param[in] name_length
 * @param[in] value
 * @return same as cass_user_type_set_user_type_by_name()
 *
 * @see cass_user_type_set_user_type_by_name()
 */
CASS_EXPORT CassError
cass_user_type_set_user_type_by_name_n(CassUserType* user_type,
                                       const char* name,
                                       size_t name_length,
                                       const CassUserType* value);

/***********************************************************************************
 *
 * Result
 *
 ***********************************************************************************/

/**
 * Frees a result instance.
 *
 * This method invalidates all values, rows, and
 * iterators that were derived from this result.
 *
 * @public @memberof CassResult
 *
 * @param[in] result
 */
CASS_EXPORT void
cass_result_free(const CassResult* result);

/**
 * Gets the number of rows for the specified result.
 *
 * @public @memberof CassResult
 *
 * @param[in] result
 * @return The number of rows in the result.
 */
CASS_EXPORT size_t
cass_result_row_count(const CassResult* result);

/**
 * Gets the number of columns per row for the specified result.
 *
 * @public @memberof CassResult
 *
 * @param[in] result
 * @return The number of columns per row in the result.
 */
CASS_EXPORT size_t
cass_result_column_count(const CassResult* result);

/**
 * Gets the column name at index for the specified result.
 *
 * @public @memberof CassResult
 *
 * @param[in] result
 * @param[in] index
 * @param[out] name The column name at the specified index.
 * @param[out] name_length
 * @return CASS_OK if successful, otherwise error occurred
 */
CASS_EXPORT CassError
cass_result_column_name(const CassResult *result,
                        size_t index,
                        const char** name,
                        size_t* name_length);

/**
 * Gets the column type at index for the specified result.
 *
 * @public @memberof CassResult
 *
 * @param[in] result
 * @param[in] index
 * @return The column type at the specified index. CASS_VALUE_TYPE_UNKNOWN
 * is returned if the index is out of bounds.
 */
CASS_EXPORT CassValueType
cass_result_column_type(const CassResult* result,
                        size_t index);

/**
 * Gets the column data type at index for the specified result.
 *
 * @public @memberof CassResult
 *
 * @param[in] result
 * @param[in] index
 * @return The column type at the specified index. NULL is returned if the
 * index is out of bounds.
 */
CASS_EXPORT const CassDataType*
cass_result_column_data_type(const CassResult* result, size_t index);

/**
 * Gets the first row of the result.
 *
 * @public @memberof CassResult
 *
 * @param[in] result
 * @return The first row of the result. NULL if there are no rows.
 */
CASS_EXPORT const CassRow*
cass_result_first_row(const CassResult* result);

/**
 * Returns true if there are more pages.
 *
 * @cassandra{2.0+}
 *
 * @public @memberof CassResult
 *
 * @param[in] result
 * @return cass_true if there are more pages
 */
CASS_EXPORT cass_bool_t
cass_result_has_more_pages(const CassResult* result);

/**
 * Gets the raw paging state from the result. The paging state is bound to the
 * lifetime of the result object. If paging state needs to live beyond the
 * lifetime of the result object it must be copied.
 *
 * <b>Warning:</b> The paging state should not be exposed to or come from
 * untrusted environments. The paging state could be spoofed and potentially
 * used to gain access to other data.
 *
 * @cassandra{2.0+}
 *
 * @public @memberof CassResult
 *
 * @param[in] result
 * @param[out] paging_state
 * @param[out] paging_state_size
 * @return CASS_OK if successful, otherwise error occurred
 *
 * @see cass_statement_set_paging_state_token()
 */
CASS_EXPORT CassError
cass_result_paging_state_token(const CassResult* result,
                               const char** paging_state,
                               size_t* paging_state_size);

/***********************************************************************************
 *
 * Error result
 *
 ***********************************************************************************/

/**
 * Frees an error result instance.
 *
 * @public @memberof CassErrorResult
 *
 * @param[in] error_result
 */
CASS_EXPORT void
cass_error_result_free(const CassErrorResult* error_result);

/**
 * Gets error code for the error result. This error code will always
 * have an server error source.
 *
 * @public @memberof CassErrorResult
 *
 * @param[in] error_result
 * @return The server error code
 */
CASS_EXPORT CassError
cass_error_result_code(const CassErrorResult* error_result);

/**
 * Gets consistency that triggered the error result of the
 * following types:
 *
 * <ul>
 *   <li>CASS_ERROR_SERVER_READ_TIMEOUT</li>
 *   <li>CASS_ERROR_SERVER_WRITE_TIMEOUT</li>
 *   <li>CASS_ERROR_SERVER_READ_FAILURE</li>
 *   <li>CASS_ERROR_SERVER_WRITE_FAILURE</li>
 *   <li>CASS_ERROR_SERVER_UNAVAILABLE</li>
 * </ul>
 *
 * @public @memberof CassErrorResult
 *
 * @param[in] error_result
 * @return The consistency that triggered the error for a read timeout,
 * write timeout or an unavailable error result. Undefined for other
 * error result types.
 */
CASS_EXPORT CassConsistency
cass_error_result_consistency(const CassErrorResult* error_result);

/**
 * Gets the actual number of received responses, received acknowledgments
 * or alive nodes for following error result types, respectively:
 *
 * <ul>
 *   <li>CASS_ERROR_SERVER_READ_TIMEOUT</li>
 *   <li>CASS_ERROR_SERVER_WRITE_TIMEOUT</li>
 *   <li>CASS_ERROR_SERVER_READ_FAILURE</li>
 *   <li>CASS_ERROR_SERVER_WRITE_FAILURE</li>
 *   <li>CASS_ERROR_SERVER_UNAVAILABLE</li>
 * </ul>
 *
 * @public @memberof CassErrorResult
 *
 * @param[in] error_result
 * @return The actual received responses for a read timeout, actual received
 * acknowledgments for a write timeout or actual alive nodes for a unavailable
 * error. Undefined for other error result types.
 */
CASS_EXPORT cass_int32_t
cass_error_result_responses_received(const CassErrorResult* error_result);

/**
 * Gets required responses, required acknowledgments or required alive nodes
 * needed to successfully complete the request for following error result types,
 * respectively:
 *
 * <ul>
 *   <li>CASS_ERROR_SERVER_READ_TIMEOUT</li>
 *   <li>CASS_ERROR_SERVER_WRITE_TIMEOUT</li>
 *   <li>CASS_ERROR_SERVER_READ_FAILURE</li>
 *   <li>CASS_ERROR_SERVER_WRITE_FAILURE</li>
 *   <li>CASS_ERROR_SERVER_UNAVAILABLE</li>
 * </ul>
 *
 * @public @memberof CassErrorResult
 *
 * @param[in] error_result
 * @return The required responses for a read time, required acknowledgments
 * for a write timeout or required alive nodes for an unavailable error result.
 * Undefined for other error result types.
 */
CASS_EXPORT cass_int32_t
cass_error_result_responses_required(const CassErrorResult* error_result);

/**
 * Gets the number of nodes that experienced failures for the following error types:
 *
 * <ul>
 *   <li>CASS_ERROR_SERVER_READ_FAILURE</li>
 *   <li>CASS_ERROR_SERVER_WRITE_FAILURE</li>
 * </ul>
 *
 * @public @memberof CassErrorResult
 *
 * @param[in] error_result
 * @return The number of nodes that failed during a read or write request.
 */
CASS_EXPORT cass_int32_t
cass_error_result_num_failures(const CassErrorResult* error_result);

/**
 * Determines whether the actual data was present in the responses from the
 * replicas for the following error result types:
 *
 * <ul>
 *   <li>CASS_ERROR_SERVER_READ_TIMEOUT</li>
 *   <li>CASS_ERROR_SERVER_READ_FAILURE</li>
 * </ul>
 *
 * @public @memberof CassErrorResult
 *
 * @param[in] error_result
 * @return cass_true if the data was present in the received responses when the
 * read timeout occurred. Undefined for other error result types.
 */
CASS_EXPORT cass_bool_t
cass_error_result_data_present(const CassErrorResult* error_result);

/**
 * Gets the write type of a request for the following error result types:
 *
 * <ul>
 *   <li>CASS_ERROR_SERVER_WRITE_TIMEOUT</li>
 *   <li>CASS_ERROR_SERVER_WRITE_FAILURE</li>
 * </ul>
 *
 * @public @memberof CassErrorResult
 *
 * @param[in] error_result
 * @return The type of the write that timed out. Undefined for
 * other error result types.
 */
CASS_EXPORT CassWriteType
cass_error_result_write_type(const CassErrorResult* error_result);

/**
 * Gets the affected keyspace for the following error result types:
 *
 * <ul>
 *   <li>CASS_ERROR_SERVER_ALREADY_EXISTS</li>
 *   <li>CASS_ERROR_SERVER_FUNCTION_FAILURE</li>
 * </ul>
 *
 * @public @memberof CassErrorResult
 *
 * @param[in] error_result
 * @param[out] keyspace
 * @param[out] keyspace_length
 * @return CASS_OK if successful, otherwise error occurred
 */
CASS_EXPORT CassError
cass_error_result_keyspace(const CassErrorResult* error_result,
                           const char** keyspace,
                           size_t* keyspace_length);

/**
 * Gets the affected table for the already exists error
 * (CASS_ERROR_SERVER_ALREADY_EXISTS) result type.
 *
 * @public @memberof CassErrorResult
 *
 * @param[in] error_result
 * @param[out] table
 * @param[out] table_length
 * @return CASS_OK if successful, otherwise error occurred
 */
CASS_EXPORT CassError
cass_error_result_table(const CassErrorResult* error_result,
                        const char** table,
                        size_t* table_length);

/**
 * Gets the affected function for the function failure error
 * (CASS_ERROR_SERVER_FUNCTION_FAILURE) result type.
 *
 * @cassandra{2.2+}
 *
 * @public @memberof CassErrorResult
 *
 * @param[in] error_result
 * @param[out] function
 * @param[out] function_length
 * @return CASS_OK if successful, otherwise error occurred
 */
CASS_EXPORT CassError
cass_error_result_function(const CassErrorResult* error_result,
                           const char** function,
                           size_t* function_length);

/**
 * Gets the number of argument types for the function failure error
 * (CASS_ERROR_SERVER_FUNCTION_FAILURE) result type.
 *
 * @cassandra{2.2+}
 *
 * @public @memberof CassErrorResult
 *
 * @param[in] error_result
 * @return The number of arguments for the affected function.
 */
CASS_EXPORT size_t
cass_error_num_arg_types(const CassErrorResult* error_result);

/**
 * Gets the argument type at the specified index for the function failure
 * error (CASS_ERROR_SERVER_FUNCTION_FAILURE) result type.
 *
 * @cassandra{2.2+}
 *
 * @public @memberof CassErrorResult
 *
 * @param[in] error_result
 * @param[in] index
 * @param[out] arg_type
 * @param[out] arg_type_length
 * @return CASS_OK if successful, otherwise error occurred
 */
CASS_EXPORT CassError
cass_error_result_arg_type(const CassErrorResult* error_result,
                           size_t index,
                           const char** arg_type,
                           size_t* arg_type_length);

/***********************************************************************************
 *
 * Iterator
 *
 ***********************************************************************************/

/**
 * Frees an iterator instance.
 *
 * @public @memberof CassIterator
 *
 * @param[in] iterator
 */
CASS_EXPORT void
cass_iterator_free(CassIterator* iterator);

/**
 * Gets the type of the specified iterator.
 *
 * @public @memberof CassIterator
 *
 * @param[in] iterator
 * @return The type of the iterator.
 */
CASS_EXPORT CassIteratorType
cass_iterator_type(CassIterator* iterator);

/**
 * Creates a new iterator for the specified result. This can be
 * used to iterate over rows in the result.
 *
 * @public @memberof CassResult
 *
 * @param[in] result
 * @return A new iterator that must be freed.
 *
 * @see cass_iterator_free()
 */
CASS_EXPORT CassIterator*
cass_iterator_from_result(const CassResult* result);

/**
 * Creates a new iterator for the specified row. This can be
 * used to iterate over columns in a row.
 *
 * @public @memberof CassRow
 *
 * @param[in] row
 * @return A new iterator that must be freed.
 *
 * @see cass_iterator_free()
 */
CASS_EXPORT CassIterator*
cass_iterator_from_row(const CassRow* row);

/**
 * Creates a new iterator for the specified collection. This can be
 * used to iterate over values in a collection.
 *
 * @public @memberof CassValue
 *
 * @param[in] value
 * @return A new iterator that must be freed. NULL returned if the
 * value is not a collection.
 *
 * @see cass_iterator_free()
 */
CASS_EXPORT CassIterator*
cass_iterator_from_collection(const CassValue* value);

/**
 * Creates a new iterator for the specified map. This can be
 * used to iterate over key/value pairs in a map.
 *
 * @public @memberof CassValue
 *
 * @param[in] value
 * @return A new iterator that must be freed. NULL returned if the
 * value is not a map.
 *
 * @see cass_iterator_free()
 */
CASS_EXPORT CassIterator*
cass_iterator_from_map(const CassValue* value);

/**
 * Creates a new iterator for the specified tuple. This can be
 * used to iterate over values in a tuple.
 *
 * @cassandra{2.1+}
 *
 * @public @memberof CassValue
 *
 * @param[in] value
 * @return A new iterator that must be freed. NULL returned if the
 * value is not a tuple.
 *
 * @see cass_iterator_free()
 */
CASS_EXPORT CassIterator*
cass_iterator_from_tuple(const CassValue* value);

/**
 * Creates a new iterator for the specified user defined type. This can be
 * used to iterate over fields in a user defined type.
 *
 * @cassandra{2.1+}
 *
 * @public @memberof CassValue
 *
 * @param[in] value
 * @return A new iterator that must be freed. NULL returned if the
 * value is not a user defined type.
 *
 * @see cass_iterator_free()
 */
CASS_EXPORT CassIterator*
cass_iterator_fields_from_user_type(const CassValue* value);

/**
 * Creates a new iterator for the specified schema metadata.
 * This can be used to iterate over keyspace.
 *
 * @public @memberof CassSchemaMeta
 *
 * @param[in] schema_meta
 * @return A new iterator that must be freed.
 *
 * @see cass_iterator_get_keyspace_meta()
 * @see cass_iterator_free()
 */
CASS_EXPORT CassIterator*
cass_iterator_keyspaces_from_schema_meta(const CassSchemaMeta* schema_meta);

/**
 * Creates a new iterator for the specified keyspace metadata.
 * This can be used to iterate over tables.
 *
 * @public @memberof CassKeyspaceMeta
 *
 * @param[in] keyspace_meta
 * @return A new iterator that must be freed.
 *
 * @see cass_iterator_get_table_meta()
 * @see cass_iterator_free()
 */
CASS_EXPORT CassIterator*
cass_iterator_tables_from_keyspace_meta(const CassKeyspaceMeta* keyspace_meta);

/**
 * Creates a new iterator for the specified keyspace metadata.
 * This can be used to iterate over views.
 *
 * @cassandra{3.0+}
 *
 * @public @memberof CassKeyspaceMeta
 *
 * @param[in] keyspace_meta
 * @return A new iterator that must be freed.
 *
 * @see cass_iterator_get_materialized_view_meta()
 * @see cass_iterator_free()
 */
CASS_EXPORT CassIterator*
cass_iterator_materialized_views_from_keyspace_meta(const CassKeyspaceMeta* keyspace_meta);

/**
 * Creates a new iterator for the specified keyspace metadata.
 * This can be used to iterate over types.
 *
 * @cassandra{2.1+}
 *
 * @public @memberof CassKeyspaceMeta
 *
 * @param[in] keyspace_meta
 * @return A new iterator that must be freed.
 *
 * @see cass_iterator_get_user_type()
 * @see cass_iterator_free()
 */
CASS_EXPORT CassIterator*
cass_iterator_user_types_from_keyspace_meta(const CassKeyspaceMeta* keyspace_meta);

/**
 * Creates a new iterator for the specified keyspace metadata.
 * This can be used to iterate over functions.
 *
 * @cassandra{2.2+}
 *
 * @public @memberof CassKeyspaceMeta
 *
 * @param[in] keyspace_meta
 * @return A new iterator that must be freed.
 *
 * @see cass_iterator_get_function_meta()
 * @see cass_iterator_free()
 */
CASS_EXPORT CassIterator*
cass_iterator_functions_from_keyspace_meta(const CassKeyspaceMeta* keyspace_meta);

/**
 * Creates a new iterator for the specified keyspace metadata.
 * This can be used to iterate over aggregates.
 *
 * @cassandra{2.2+}
 *
 * @public @memberof CassKeyspaceMeta
 *
 * @param[in] keyspace_meta
 * @return A new iterator that must be freed.
 *
 * @see cass_iterator_get_aggregate_meta()
 * @see cass_iterator_free()
 */
CASS_EXPORT CassIterator*
cass_iterator_aggregates_from_keyspace_meta(const CassKeyspaceMeta* keyspace_meta);

/**
 * Creates a new fields iterator for the specified keyspace metadata. Metadata
 * fields allow direct access to the column data found in the underlying
 * "keyspaces" metadata table. This can be used to iterate those metadata
 * field entries.
 *
 * @public @memberof CassKeyspaceMeta
 *
 * @param[in] keyspace_meta
 * @return A new iterator that must be freed.
 *
 * @see cass_iterator_get_meta_field_name()
 * @see cass_iterator_get_meta_field_value()
 * @see cass_iterator_free()
 */
CASS_EXPORT CassIterator*
cass_iterator_fields_from_keyspace_meta(const CassKeyspaceMeta* keyspace_meta);

/**
 * Creates a new iterator for the specified table metadata.
 * This can be used to iterate over columns.
 *
 * @public @memberof CassTableMeta
 *
 * @param[in] table_meta
 * @return A new iterator that must be freed.
 *
 * @see cass_iterator_get_column_meta()
 * @see cass_iterator_free()
 */
CASS_EXPORT CassIterator*
cass_iterator_columns_from_table_meta(const CassTableMeta* table_meta);

/**
 * Creates a new iterator for the specified table metadata.
 * This can be used to iterate over indexes.
 *
 * @public @memberof CassTableMeta
 *
 * @param[in] table_meta
 * @return A new iterator that must be freed.
 *
 * @see cass_iterator_get_index_meta()
 * @see cass_iterator_free()
 */
CASS_EXPORT CassIterator*
cass_iterator_indexes_from_table_meta(const CassTableMeta* table_meta);

/**
 * Creates a new iterator for the specified materialized view metadata.
 * This can be used to iterate over columns.
 *
 * @cassandra{3.0+}
 *
 * @public @memberof CassTableMeta
 *
 * @param[in] table_meta
 * @return A new iterator that must be freed.
 *
 * @see cass_iterator_get_materialized_view_meta()
 * @see cass_iterator_free()
 */
CASS_EXPORT CassIterator*
cass_iterator_materialized_views_from_table_meta(const CassTableMeta* table_meta);

/**
 * Creates a new fields iterator for the specified table metadata. Metadata
 * fields allow direct access to the column data found in the underlying
 * "tables" metadata table. This can be used to iterate those metadata
 * field entries.
 *
 * @public @memberof CassTableMeta
 *
 * @param[in] table_meta
 * @return A new iterator that must be freed.
 *
 * @see cass_iterator_get_meta_field_name()
 * @see cass_iterator_get_meta_field_value()
 * @see cass_iterator_free()
 */
CASS_EXPORT CassIterator*
cass_iterator_fields_from_table_meta(const CassTableMeta* table_meta);

/**
 * Creates a new iterator for the specified materialized view metadata.
 * This can be used to iterate over columns.
 *
 * @cassandra{3.0+}
 *
 * @public @memberof CassMaterializedViewMeta
 *
 * @param[in] view_meta
 * @return A new iterator that must be freed.
 *
 * @see cass_iterator_get_column_meta()
 * @see cass_iterator_free()
 */
CASS_EXPORT CassIterator*
cass_iterator_columns_from_materialized_view_meta(const CassMaterializedViewMeta* view_meta);

/**
 * Creates a new fields iterator for the specified materialized view metadata.
 * Metadata fields allow direct access to the column data found in the
 * underlying "views" metadata view. This can be used to iterate those metadata
 * field entries.
 *
 * @cassandra{3.0+}
 *
 * @public @memberof CassMaterializedViewMeta
 *
 * @param[in] view_meta
 * @return A new iterator that must be freed.
 *
 * @see cass_iterator_get_meta_field_name()
 * @see cass_iterator_get_meta_field_value()
 * @see cass_iterator_free()
 */
CASS_EXPORT CassIterator*
cass_iterator_fields_from_materialized_view_meta(const CassMaterializedViewMeta* view_meta);

/**
 * Creates a new fields iterator for the specified column metadata. Metadata
 * fields allow direct access to the column data found in the underlying
 * "columns" metadata table. This can be used to iterate those metadata
 * field entries.
 *
 * @public @memberof CassColumnMeta
 *
 * @param[in] column_meta
 * @return A new iterator that must be freed.
 *
 * @see cass_iterator_get_meta_field_name()
 * @see cass_iterator_get_meta_field_value()
 * @see cass_iterator_free()
 */
CASS_EXPORT CassIterator*
cass_iterator_fields_from_column_meta(const CassColumnMeta* column_meta);

/**
 * Creates a new fields iterator for the specified index metadata. Metadata
 * fields allow direct access to the index data found in the underlying
 * "indexes" metadata table. This can be used to iterate those metadata
 * field entries.
 *
 * @public @memberof CassIndexMeta
 *
 * @param[in] index_meta
 * @return A new iterator that must be freed.
 *
 * @see cass_iterator_get_meta_field_name()
 * @see cass_iterator_get_meta_field_value()
 * @see cass_iterator_free()
 */
CASS_EXPORT CassIterator*
cass_iterator_fields_from_index_meta(const CassIndexMeta* index_meta);

/**
 * Creates a new fields iterator for the specified function metadata. Metadata
 * fields allow direct access to the column data found in the underlying
 * "functions" metadata table. This can be used to iterate those metadata
 * field entries.
 *
 * @cassandra{2.2+}
 *
 * @public @memberof CassFunctionMeta
 *
 * @param[in] function_meta
 * @return A new iterator that must be freed.
 *
 * @see cass_iterator_get_meta_field()
 * @see cass_iterator_free()
 */
CASS_EXPORT CassIterator*
cass_iterator_fields_from_function_meta(const CassFunctionMeta* function_meta);

/**
 * Creates a new fields iterator for the specified aggregate metadata. Metadata
 * fields allow direct access to the column data found in the underlying
 * "aggregates" metadata table. This can be used to iterate those metadata
 * field entries.
 *
 * @cassandra{2.2+}
 *
 * @public @memberof CassAggregateMeta
 *
 * @param[in] aggregate_meta
 * @return A new iterator that must be freed.
 *
 * @see cass_iterator_get_meta_field()
 * @see cass_iterator_free()
 */
CASS_EXPORT CassIterator*
cass_iterator_fields_from_aggregate_meta(const CassAggregateMeta* aggregate_meta);

/**
 * Advance the iterator to the next row, column or collection item.
 *
 * @public @memberof CassIterator
 *
 * @param[in] iterator
 * @return false if no more rows, columns or items, otherwise true
 */
CASS_EXPORT cass_bool_t
cass_iterator_next(CassIterator* iterator);

/**
 * Gets the row at the result iterator's current position.
 *
 * Calling cass_iterator_next() will invalidate the previous
 * row returned by this method.
 *
 * @public @memberof CassIterator
 *
 * @param[in] iterator
 * @return A row
 */
CASS_EXPORT const CassRow*
cass_iterator_get_row(const CassIterator* iterator);

/**
 * Gets the column value at the row iterator's current position.
 *
 * Calling cass_iterator_next() will invalidate the previous
 * column returned by this method.
 *
 * @public @memberof CassIterator
 *
 * @param[in] iterator
 * @return A value
 */
CASS_EXPORT const CassValue*
cass_iterator_get_column(const CassIterator* iterator);

/**
 * Gets the value at a collection or tuple iterator's current position.
 *
 * Calling cass_iterator_next() will invalidate the previous
 * value returned by this method.
 *
 * @public @memberof CassIterator
 *
 * @param[in] iterator
 * @return A value
 */
CASS_EXPORT const CassValue*
cass_iterator_get_value(const CassIterator* iterator);

/**
 * Gets the key at the map iterator's current position.
 *
 * Calling cass_iterator_next() will invalidate the previous
 * value returned by this method.
 *
 * @public @memberof CassIterator
 *
 * @param[in] iterator
 * @return A value
 */
CASS_EXPORT const CassValue*
cass_iterator_get_map_key(const CassIterator* iterator);


/**
 * Gets the value at the map iterator's current position.
 *
 * Calling cass_iterator_next() will invalidate the previous
 * value returned by this method.
 *
 * @public @memberof CassIterator
 *
 * @param[in] iterator
 * @return A value
 */
CASS_EXPORT const CassValue*
cass_iterator_get_map_value(const CassIterator* iterator);

/**
 * Gets the field name at the user type defined iterator's current position.
 *
 * Calling cass_iterator_next() will invalidate the previous
 * name returned by this method.
 *
 * @cassandra{2.1+}
 *
 * @public @memberof CassIterator
 *
 * @param[in] iterator
 * @param[out] name
 * @param[out] name_length
 * @return CASS_OK if successful, otherwise error occurred
 */
CASS_EXPORT CassError
cass_iterator_get_user_type_field_name(const CassIterator* iterator,
                                       const char** name,
                                       size_t* name_length);

/**
 * Gets the field value at the user type defined iterator's current position.
 *
 * Calling cass_iterator_next() will invalidate the previous
 * value returned by this method.
 *
 * @cassandra{2.1+}
 *
 * @public @memberof CassIterator
 *
 * @param[in] iterator
 * @return A value
 */
CASS_EXPORT const CassValue*
cass_iterator_get_user_type_field_value(const CassIterator* iterator);

/**
 * Gets the keyspace metadata entry at the iterator's current position.
 *
 * Calling cass_iterator_next() will invalidate the previous
 * value returned by this method.
 *
 * @public @memberof CassIterator
 *
 * @param[in] iterator
 * @return A keyspace metadata entry
 */
CASS_EXPORT const CassKeyspaceMeta*
cass_iterator_get_keyspace_meta(const CassIterator* iterator);

/**
 * Gets the table metadata entry at the iterator's current position.
 *
 * Calling cass_iterator_next() will invalidate the previous
 * value returned by this method.
 *
 * @public @memberof CassIterator
 *
 * @param[in] iterator
 * @return A table metadata entry
 */
CASS_EXPORT const CassTableMeta*
cass_iterator_get_table_meta(const CassIterator* iterator);

/**
 * Gets the materialized view metadata entry at the iterator's current position.
 *
 * Calling cass_iterator_next() will invalidate the previous
 * value returned by this method.
 *
 * @cassandra{3.0+}
 *
 * @public @memberof CassIterator
 *
 * @param[in] iterator
 * @return A materialized view metadata entry
 */
CASS_EXPORT const CassMaterializedViewMeta*
cass_iterator_get_materialized_view_meta(const CassIterator* iterator);

/**
 * Gets the type metadata entry at the iterator's current position.
 *
 * Calling cass_iterator_next() will invalidate the previous
 * value returned by this method.
 *
 * @cassandra{2.1+}
 *
 * @public @memberof CassIterator
 *
 * @param[in] iterator
 * @return A type metadata entry
 */
CASS_EXPORT const CassDataType*
cass_iterator_get_user_type(const CassIterator* iterator);

/**
 * Gets the function metadata entry at the iterator's current position.
 *
 * Calling cass_iterator_next() will invalidate the previous
 * value returned by this method.
 *
 * @cassandra{2.2+}
 *
 * @public @memberof CassIterator
 *
 * @param[in] iterator
 * @return A function metadata entry
 */
CASS_EXPORT const CassFunctionMeta*
cass_iterator_get_function_meta(const CassIterator* iterator);

/**
 * Gets the aggregate metadata entry at the iterator's current position.
 *
 * Calling cass_iterator_next() will invalidate the previous
 * value returned by this method.
 *
 * @cassandra{2.2+}
 *
 * @public @memberof CassIterator
 *
 * @param[in] iterator
 * @return A aggregate metadata entry
 */
CASS_EXPORT const CassAggregateMeta*
cass_iterator_get_aggregate_meta(const CassIterator* iterator);

/**
 * Gets the column metadata entry at the iterator's current position.
 *
 * Calling cass_iterator_next() will invalidate the previous
 * value returned by this method.
 *
 * @public @memberof CassIterator
 *
 * @param[in] iterator
 * @return A column metadata entry
 */
CASS_EXPORT const CassColumnMeta*
cass_iterator_get_column_meta(const CassIterator* iterator);

/**
 * Gets the index metadata entry at the iterator's current position.
 *
 * Calling cass_iterator_next() will invalidate the previous
 * value returned by this method.
 *
 * @public @memberof CassIterator
 *
 * @param[in] iterator
 * @return A index metadata entry
 */
CASS_EXPORT const CassIndexMeta*
cass_iterator_get_index_meta(const CassIterator* iterator);

/**
 * Gets the metadata field name at the iterator's current position.
 *
 * Calling cass_iterator_next() will invalidate the previous
 * value returned by this method.
 *
 * @public @memberof CassIterator
 *
 * @param[in] iterator
 * @param[out] name
 * @param[out] name_length
 * @return CASS_OK if successful, otherwise error occurred
 */
CASS_EXPORT CassError
cass_iterator_get_meta_field_name(const CassIterator* iterator,
                                  const char** name,
                                  size_t* name_length);

/**
 * Gets the metadata field value at the iterator's current position.
 *
 * Calling cass_iterator_next() will invalidate the previous
 * value returned by this method.
 *
 * @public @memberof CassIterator
 *
 * @param[in] iterator
 * @return A metadata field value
 */
CASS_EXPORT const CassValue*
cass_iterator_get_meta_field_value(const CassIterator* iterator);

/***********************************************************************************
 *
 * Row
 *
 ***********************************************************************************/

/**
 * Get the column value at index for the specified row.
 *
 * @public @memberof CassRow
 *
 * @param[in] row
 * @param[in] index
 * @return The column value at the specified index. NULL is
 * returned if the index is out of bounds.
 */
CASS_EXPORT const CassValue*
cass_row_get_column(const CassRow* row,
                    size_t index);


/**
 * Get the column value by name for the specified row.
 *
 * @public @memberof CassRow
 *
 * @param[in] row
 * @param[in] name
 * @return The column value for the specified name. NULL is
 * returned if the column does not exist.
 */
CASS_EXPORT const CassValue*
cass_row_get_column_by_name(const CassRow* row,
                            const char* name);

/**
 * Same as cass_row_get_column_by_name(), but with lengths for string
 * parameters.
 *
 * @public @memberof CassRow
 *
 * @param[in] row
 * @param[in] name
 * @param[in] name_length
 * @return same as cass_row_get_column_by_name()
 *
 * @see cass_row_get_column_by_name()
 */
CASS_EXPORT const CassValue*
cass_row_get_column_by_name_n(const CassRow* row,
                              const char* name,
                              size_t name_length);

/***********************************************************************************
 *
 * Value
 *
 ***********************************************************************************/

/**
 * Gets the data type of a value.
 *
 * @public @memberof CassValue
 *
 * @param[in] value
 * @return Returns a reference to the data type of the value.
 * Do not free this reference as it is bound to the lifetime of the value.
 */
CASS_EXPORT const CassDataType*
cass_value_data_type(const CassValue* value);

/**
 * Gets an int8 for the specified value.
 *
 * @cassandra{2.2+}
 *
 * @public @memberof CassValue
 *
 * @param[in] value
 * @param[out] output
 * @return CASS_OK if successful, otherwise error occurred
 */
CASS_EXPORT CassError
cass_value_get_int8(const CassValue* value,
                     cass_int8_t* output);

/**
 * Gets an int16 for the specified value.
 *
 * @cassandra{2.2+}
 *
 * @public @memberof CassValue
 *
 * @param[in] value
 * @param[out] output
 * @return CASS_OK if successful, otherwise error occurred
 */
CASS_EXPORT CassError
cass_value_get_int16(const CassValue* value,
                     cass_int16_t* output);

/**
 * Gets an int32 for the specified value.
 *
 * @public @memberof CassValue
 *
 * @param[in] value
 * @param[out] output
 * @return CASS_OK if successful, otherwise error occurred
 */
CASS_EXPORT CassError
cass_value_get_int32(const CassValue* value,
                     cass_int32_t* output);

/**
 * Gets an uint32 for the specified value.
 *
 * @cassandra{2.2+}
 *
 * @public @memberof CassValue
 *
 * @param[in] value
 * @param[out] output
 * @return CASS_OK if successful, otherwise error occurred
 */
CASS_EXPORT CassError
cass_value_get_uint32(const CassValue* value,
                      cass_uint32_t* output);

/**
 * Gets an int64 for the specified value.
 *
 * @public @memberof CassValue
 *
 * @param[in] value
 * @param[out] output
 * @return CASS_OK if successful, otherwise error occurred
 */
CASS_EXPORT CassError
cass_value_get_int64(const CassValue* value,
                     cass_int64_t* output);

/**
 * Gets a float for the specified value.
 *
 * @public @memberof CassValue
 *
 * @param[in] value
 * @param[out] output
 * @return CASS_OK if successful, otherwise error occurred
 */
CASS_EXPORT CassError
cass_value_get_float(const CassValue* value,
                     cass_float_t* output);

/**
 * Gets a double for the specified value.
 *
 * @public @memberof CassValue
 *
 * @param[in] value
 * @param[out] output
 * @return CASS_OK if successful, otherwise error occurred
 */
CASS_EXPORT CassError
cass_value_get_double(const CassValue* value,
                      cass_double_t* output);

/**
 * Gets a bool for the specified value.
 *
 * @public @memberof CassValue
 *
 * @param[in] value
 * @param[out] output
 * @return CASS_OK if successful, otherwise error occurred
 */
CASS_EXPORT CassError
cass_value_get_bool(const CassValue* value,
                    cass_bool_t* output);

/**
 * Gets a UUID for the specified value.
 *
 * @public @memberof CassValue
 *
 * @param[in] value
 * @param[out] output
 * @return CASS_OK if successful, otherwise error occurred
 */
CASS_EXPORT CassError
cass_value_get_uuid(const CassValue* value,
                    CassUuid* output);

/**
 * Gets an INET for the specified value.
 *
 * @public @memberof CassValue
 *
 * @param[in] value
 * @param[out] output
 * @return CASS_OK if successful, otherwise error occurred
 */
CASS_EXPORT CassError
cass_value_get_inet(const CassValue* value,
                    CassInet* output);

/**
 * Gets a string for the specified value.
 *
 * @public @memberof CassValue
 *
 * @param[in] value
 * @param[out] output
 * @param[out] output_size
 * @return CASS_OK if successful, otherwise error occurred
 */
CASS_EXPORT CassError
cass_value_get_string(const CassValue* value,
                      const char** output,
                      size_t* output_size);

/**
 * Gets the bytes of the specified value.
 *
 * @public @memberof CassValue
 *
 * @param[in] value
 * @param[out] output
 * @param[out] output_size
 * @return CASS_OK if successful, otherwise error occurred
 */
CASS_EXPORT CassError
cass_value_get_bytes(const CassValue* value,
                     const cass_byte_t** output,
                     size_t* output_size);

/**
 * Gets a decimal for the specified value.
 *
 * @public @memberof CassValue
 *
 * @param[in] value
 * @param[out] varint
 * @param[out] varint_size
 * @param[out] scale
 * @return CASS_OK if successful, otherwise error occurred
 */
CASS_EXPORT CassError
cass_value_get_decimal(const CassValue* value,
                       const cass_byte_t** varint,
                       size_t* varint_size,
                       cass_int32_t* scale);

/**
 * Gets a duration for the specified value.
 *
 * @cassandra{3.10+}
 *
 * @public @memberof CassValue
 *
 * @param[in] value
 * @param[out] months
 * @param[out] days
 * @param[out] nanos
 * @return CASS_OK if successful, otherwise error occurred
 */
CASS_EXPORT CassError
cass_value_get_duration(const CassValue* value,
                        cass_int32_t* months,
                        cass_int32_t* days,
                        cass_int64_t* nanos);

/**
 * Gets the type of the specified value.
 *
 * @public @memberof CassValue
 *
 * @param[in] value
 * @return The type of the specified value.
 */
CASS_EXPORT CassValueType
cass_value_type(const CassValue* value);

/**
 * Returns true if a specified value is null.
 *
 * @public @memberof CassValue
 *
 * @param[in] value
 * @return true if the value is null, otherwise false.
 */
CASS_EXPORT cass_bool_t
cass_value_is_null(const CassValue* value);

/**
 * Returns true if a specified value is a collection.
 *
 * @public @memberof CassValue
 *
 * @param[in] value
 * @return true if the value is a collection, otherwise false.
 */
CASS_EXPORT cass_bool_t
cass_value_is_collection(const CassValue* value);

/**
 * Returns true if a specified value is a duration.
 *
 * @public @memberof CassValue
 *
 * @param[in] value
 * @return true if the value is a duration, otherwise false.
 */
CASS_EXPORT cass_bool_t
cass_value_is_duration(const CassValue* value);

/**
 * Get the number of items in a collection. Works for all collection types.
 *
 * @public @memberof CassValue
 *
 * @param[in] collection
 * @return Count of items in a collection. 0 if not a collection.
 */
CASS_EXPORT size_t
cass_value_item_count(const CassValue* collection);

/**
 * Get the primary sub-type for a collection. This returns the sub-type for a
 * list or set and the key type for a map.
 *
 * @public @memberof CassValue
 *
 * @param[in] collection
 * @return The type of the primary sub-type. CASS_VALUE_TYPE_UNKNOWN
 * returned if not a collection.
 */
CASS_EXPORT CassValueType
cass_value_primary_sub_type(const CassValue* collection);

/**
 * Get the secondary sub-type for a collection. This returns the value type for a
 * map.
 *
 * @public @memberof CassValue
 *
 * @param[in] collection
 * @return The type of the primary sub-type. CASS_VALUE_TYPE_UNKNOWN
 * returned if not a collection or not a map.
 */
CASS_EXPORT CassValueType
cass_value_secondary_sub_type(const CassValue* collection);


/***********************************************************************************
 *
 * UUID
 *
 ************************************************************************************/

/**
 * Creates a new UUID generator.
 *
 * <b>Note:</b> This object is thread-safe. It is best practice to create and reuse
 * a single object per application.
 *
 * <b>Note:</b> If unique node information (IP address) is unable to be determined
 * then random node information will be generated.
 *
 * @public @memberof CassUuidGen
 *
 * @return Returns a UUID generator that must be freed.
 *
 * @see cass_uuid_gen_free()
 * @see cass_uuid_gen_new_with_node()
 */
CASS_EXPORT CassUuidGen*
cass_uuid_gen_new();

/**
 * Creates a new UUID generator with custom node information.
 *
 * <b>Note:</b> This object is thread-safe. It is best practice to create and reuse
 * a single object per application.
 *
 * @public @memberof CassUuidGen
 *
 * @return Returns a UUID generator that must be freed.
 *
 * @see cass_uuid_gen_free()
 */
CASS_EXPORT CassUuidGen*
cass_uuid_gen_new_with_node(cass_uint64_t node);

/**
 * Frees a UUID generator instance.
 *
 * @public @memberof CassUuidGen
 *
 * @param[in] uuid_gen
 */
CASS_EXPORT void
cass_uuid_gen_free(CassUuidGen* uuid_gen);

/**
 * Generates a V1 (time) UUID.
 *
 * <b>Note:</b> This method is thread-safe
 *
 * @public @memberof CassUuidGen
 *
 * @param[in] uuid_gen
 * @param[out] output A V1 UUID for the current time.
 */
CASS_EXPORT void
cass_uuid_gen_time(CassUuidGen* uuid_gen,
                   CassUuid* output);

/**
 * Generates a new V4 (random) UUID
 *
 * <b>Note:</b>: This method is thread-safe
 *
 * @public @memberof CassUuidGen
 *
 * @param[in] uuid_gen
 * @param output A randomly generated V4 UUID.
 */
CASS_EXPORT void
cass_uuid_gen_random(CassUuidGen* uuid_gen,
                     CassUuid* output);

/**
 * Generates a V1 (time) UUID for the specified time.
 *
 * <b>Note:</b>: This method is thread-safe
 *
 * @public @memberof CassUuidGen
 *
 * @param[in] uuid_gen
 * @param[in] timestamp
 * @param[out] output A V1 UUID for the specified time.
 */
CASS_EXPORT void
cass_uuid_gen_from_time(CassUuidGen* uuid_gen,
                        cass_uint64_t timestamp,
                        CassUuid* output);

/**
 * Sets the UUID to the minimum V1 (time) value for the specified time.
 *
 * @public @memberof CassUuid
 *
 * @param[in] time
 * @param[out] output A minimum V1 UUID for the specified time.
 */
CASS_EXPORT void
cass_uuid_min_from_time(cass_uint64_t time,
                        CassUuid* output);

/**
 * Sets the UUID to the maximum V1 (time) value for the specified time.
 *
 * @public @memberof CassUuid
 *
 * @param[in] time
 * @param[out] output A maximum V1 UUID for the specified time.
 */
CASS_EXPORT void
cass_uuid_max_from_time(cass_uint64_t time,
                        CassUuid* output);

/**
 * Gets the timestamp for a V1 UUID
 *
 * @public @memberof CassUuid
 *
 * @param[in] uuid
 * @return The timestamp in milliseconds since the Epoch
 * (00:00:00 UTC on 1 January 1970). 0 returned if the UUID
 * is not V1.
 */
CASS_EXPORT cass_uint64_t
cass_uuid_timestamp(CassUuid uuid);

/**
 * Gets the version for a UUID
 *
 * @public @memberof CassUuid
 *
 * @param[in] uuid
 * @return The version of the UUID (1 or 4)
 */
CASS_EXPORT cass_uint8_t
cass_uuid_version(CassUuid uuid);

/**
 * Returns a null-terminated string for the specified UUID.
 *
 * @public @memberof CassUuid
 *
 * @param[in] uuid
 * @param[out] output A null-terminated string of length CASS_UUID_STRING_LENGTH.
 */
CASS_EXPORT void
cass_uuid_string(CassUuid uuid,
                 char* output);

/**
 * Returns a UUID for the specified string.
 *
 * Example: "550e8400-e29b-41d4-a716-446655440000"
 *
 * @public @memberof CassUuid
 *
 * @param[in] str
 * @param[out] output
 */
CASS_EXPORT CassError
cass_uuid_from_string(const char* str,
                      CassUuid* output);

/**
 * Same as cass_uuid_from_string(), but with lengths for string
 * parameters.
 *
 * @public @memberof CassUuid
 *
 * @param[in] str
 * @param[in] str_length
 * @param[out] output
 * @return same as cass_uuid_from_string()
 *
 * @see cass_uuid_from_string()
 */
CASS_EXPORT CassError
cass_uuid_from_string_n(const char* str,
                        size_t str_length,
                        CassUuid* output);

/***********************************************************************************
 *
 * Timestamp generators
 *
 ***********************************************************************************/

/**
 * Creates a new server-side timestamp generator. This generator allows Cassandra
 * to assign timestamps server-side.
 *
 * <b>Note:</b> This is the default timestamp generator.
 *
 * @cassandra{2.1+}
 *
 * @public @memberof CassTimestampGen
 *
 * @return Returns a timestamp generator that must be freed.
 *
 * @see cass_timestamp_gen_free()
 */
CASS_EXPORT CassTimestampGen*
cass_timestamp_gen_server_side_new();

/**
 * Creates a new monotonically increasing timestamp generator with microsecond
 * precision.
 *
 * This implementation guarantees a monotonically increasing timestamp. If the
 * timestamp generation rate exceeds one per microsecond or if the clock skews
 * into the past the generator will artificially increment the previously
 * generated timestamp until the request rate decreases or the clock skew
 * is corrected.
 *
 * By default, this timestamp generator will generate warnings if more than
 * 1 second of clock skew is detected. It will print an error every second until
 * the clock skew is resolved. These settings can be changed by using
 * `cass_timestamp_gen_monotonic_new_with_settings()` to create the generator
 * instance.
 *
 * <b>Note:</b> This generator is thread-safe and can be shared by multiple
 * sessions.
 *
 * @cassandra{2.1+}
 *
 * @public @memberof CassTimestampGen
 *
 * @return Returns a timestamp generator that must be freed.
 *
 * @see cass_timestamp_gen_monotonic_new_with_settings();
 * @see cass_timestamp_gen_free()
 */
CASS_EXPORT CassTimestampGen*
cass_timestamp_gen_monotonic_new();

/**
 * Same as cass_timestamp_gen_monotonic_new(), but with settings for controlling
 * warnings about clock skew.
 *
 * @param warning_threshold_us The amount of clock skew, in microseconds, that
 * must be detected before a warning is triggered. A threshold less than 0 can
 * be used to disable warnings.
 * @param warning_interval_ms The amount of time, in milliseconds, to wait before
 * warning again about clock skew. An interval value less than or equal to 0 allows
 * the warning to be triggered every millisecond.
 * @return Returns a timestamp generator that must be freed.
 */
CASS_EXPORT CassTimestampGen*
cass_timestamp_gen_monotonic_new_with_settings(cass_int64_t warning_threshold_us,
                                               cass_int64_t warning_interval_ms);

/**
 * Frees a timestamp generator instance.
 *
 * @cassandra{2.1+}
 *
 * @public @memberof CassTimestampGen
 *
 * @param[in] timestamp_gen
 */
CASS_EXPORT void
cass_timestamp_gen_free(CassTimestampGen* timestamp_gen);


/***********************************************************************************
 *
 * Retry policies
 *
 ***********************************************************************************/

/**
 * Creates a new default retry policy.
 *
 * This policy retries queries in the following cases:
 * <ul>
 *   <li>On a read timeout, if enough replicas replied but data was not received.</li>
 *   <li>On a write timeout, if a timeout occurs while writing the distributed batch log</li>
 *   <li>On unavailable, it will move to the next host</li>
 * </ul>
 *
 * In all other cases the error will be returned.
 *
 * This policy always uses the query's original consistency level.
 *
 * @public @memberof CassRetryPolicy
 *
 * @return Returns a retry policy that must be freed.
 *
 * @see cass_retry_policy_free()
 */
CASS_EXPORT CassRetryPolicy*
cass_retry_policy_default_new();

/**
 * Creates a new downgrading consistency retry policy.
 *
 * <b>Important:</b> This policy may attempt to retry requests with a lower
 * consistency level. Using this policy can break consistency guarantees.
 *
 * This policy will retry in the same scenarios as the default policy, but
 * it will also retry in the following cases:
 * <ul>
 *   <li>On a read timeout, if some replicas responded but is lower than
 *   required by the current consistency level then retry with a lower
 *   consistency level.</li>
 *   <li>On a write timeout, Retry unlogged batches at a lower consistency level
 *   if at least one replica responded. For single queries and batch if any
 *    replicas responded then consider the request successful and swallow the
 *    error.</li>
 *   <li>On unavailable, retry at a lower consistency if at lease one replica
 *   responded.</li>
 * </ul>
 *
 * This goal of this policy is to attempt to save a request if there's any
 * chance of success. A writes succeeds as long as there's a single copy
 * persisted and a read will succeed if there's some data available even
 * if it increases the risk of reading stale data.
 *
 * @deprecated This still works, but should not be used in new applications. It
 * can lead to unexpected behavior when the cluster is in a degraded state.
 * Instead, applications should prefer using the lowest consistency level on
 * statements that can be tolerated by a specific use case.
 *
 * @public @memberof CassRetryPolicy
 *
 * @return Returns a retry policy that must be freed.
 *
 * @see cass_retry_policy_free()
 */
CASS_EXPORT CASS_DEPRECATED(CassRetryPolicy*
cass_retry_policy_downgrading_consistency_new());

/**
 * Creates a new fallthrough retry policy.
 *
 * This policy never retries or ignores a server-side failure. The error
 * is always returned.
 *
 * @public @memberof CassRetryPolicy
 *
 * @return Returns a retry policy that must be freed.
 *
 * @see cass_retry_policy_free()
 */
CASS_EXPORT CassRetryPolicy*
cass_retry_policy_fallthrough_new();

/**
 * Creates a new logging retry policy.
 *
 * This policy logs the retry decision of its child policy. Logging is
 * done using CASS_LOG_INFO.
 *
 * @public @memberof CassRetryPolicy
 *
 * @param[in] child_retry_policy
 * @return Returns a retry policy that must be freed. NULL is returned if
 * the child_policy is a logging retry policy.
 *
 * @see cass_retry_policy_free()
 */
CASS_EXPORT CassRetryPolicy*
cass_retry_policy_logging_new(CassRetryPolicy* child_retry_policy);

/**
 * Frees a retry policy instance.
 *
 * @public @memberof CassRetryPolicy
 *
 * @param[in] policy
 */
CASS_EXPORT void
cass_retry_policy_free(CassRetryPolicy* policy);

/***********************************************************************************
 *
 * Custom payload
 *
 ***********************************************************************************/

/**
 * Creates a new custom payload.
 *
 * @public @memberof CassCustomPayload
 *
 * @cassandra{2.2+}
 *
 * @return Returns a custom payload that must be freed.
 *
 * @see cass_custom_payload_free()
 */
CASS_EXPORT CassCustomPayload*
cass_custom_payload_new();

/**
 * Frees a custom payload instance.
 *
 * @cassandra{2.2+}
 *
 * @public @memberof CassCustomPayload
 *
 * @param[in] payload
 */
CASS_EXPORT void
cass_custom_payload_free(CassCustomPayload* payload);

/**
 * Sets an item to the custom payload.
 *
 * @cassandra{2.2+}
 *
 * @public @memberof CassCustomPayload
 *
 * @param[in] payload
 * @param[in] name
 * @param[in] value
 * @param[in] value_size
 */
CASS_EXPORT void
cass_custom_payload_set(CassCustomPayload* payload,
                        const char* name,
                        const cass_byte_t* value,
                        size_t value_size);

/**
 * Same as cass_custom_payload_set(), but with lengths for string
 * parameters.
 *
 * @cassandra{2.2+}
 *
 * @public @memberof CassCustomPayload
 *
 * @param[in] payload
 * @param[in] name
 * @param[in] name_length
 * @param[in] value
 * @param[in] value_size
 */
CASS_EXPORT void
cass_custom_payload_set_n(CassCustomPayload* payload,
                          const char* name,
                          size_t name_length,
                          const cass_byte_t* value,
                          size_t value_size);

/**
 * Removes an item from the custom payload.
 *
 * @cassandra{2.2+}
 *
 * @public @memberof CassCustomPayload
 *
 * @param[in] payload
 * @param[in] name
 */
CASS_EXPORT void
cass_custom_payload_remove(CassCustomPayload* payload,
                           const char* name);

/**
 * Same as cass_custom_payload_set(), but with lengths for string
 * parameters.
 *
 * @cassandra{2.2+}
 *
 * @public @memberof CassCustomPayload
 *
 * @param[in] payload
 * @param[in] name
 * @param[in] name_length
 */
CASS_EXPORT void
cass_custom_payload_remove_n(CassCustomPayload* payload,
                             const char* name,
                             size_t name_length);


/***********************************************************************************
 *
 * Consistency
 *
 ***********************************************************************************/

/**
 * Gets the string for a consistency.
 *
 * @param[in] consistency
 * @return A null-terminated string for the consistency.
 * Example: "ALL", "ONE", "QUORUM", etc.
 */
CASS_EXPORT const char*
cass_consistency_string(CassConsistency consistency);

/***********************************************************************************
 *
 * Write type
 *
 ***********************************************************************************/
/**
 * Gets the string for a write type.
 *
 * @param[in] write_type
 * @return A null-terminated string for the write type.
 * Example: "BATCH", "SIMPLE", "COUNTER", etc.
 */
CASS_EXPORT const char*
cass_write_type_string(CassWriteType write_type);

/***********************************************************************************
 *
 * Error
 *
 ***********************************************************************************/

/**
 * Gets a description for an error code.
 *
 * @param[in] error
 * @return A null-terminated string describing the error.
 */
CASS_EXPORT const char*
cass_error_desc(CassError error);

/***********************************************************************************
 *
 * Log
 *
 ***********************************************************************************/

/**
 * Explicitly wait for the log to flush and deallocate resources.
 * This *MUST* be the last call using the library. It is an error
 * to call any cass_*() functions after this call.
 *
 * @deprecated This is no longer useful and does nothing. Expect this to be
 * removed in a future release.
 */
CASS_EXPORT CASS_DEPRECATED(void
cass_log_cleanup());

/**
 * Sets the log level.
 *
 * <b>Note:</b> This needs to be done before any call that might log, such as
 * any of the cass_cluster_*() or cass_ssl_*() functions.
 *
 * <b>Default:</b> CASS_LOG_WARN
 *
 * @param[in] log_level
 */
CASS_EXPORT void
cass_log_set_level(CassLogLevel log_level);

/**
 * Sets a callback for handling logging events.
 *
 * <b>Note:</b> This needs to be done before any call that might log, such as
 * any of the cass_cluster_*() or cass_ssl_*() functions.
 *
 * <b>Default:</b> An internal callback that prints to stderr
 *
 * @param[in] data An opaque data object passed to the callback.
 * @param[in] callback A callback that handles logging events. This is
 * called in a separate thread so access to shared data must be synchronized.
 */
CASS_EXPORT void
cass_log_set_callback(CassLogCallback callback,
                      void* data);

/**
 * Sets the log queue size.
 *
 * <b>Note:</b> This needs to be done before any call that might log, such as
 * any of the cass_cluster_*() or cass_ssl_*() functions.
 *
 * <b>Default:</b> 2048
 *
 * @deprecated This is no longer useful and does nothing. Expect this to be
 * removed in a future release.
 *
 * @param[in] queue_size
 */
CASS_EXPORT CASS_DEPRECATED(void
cass_log_set_queue_size(size_t queue_size));

/**
 * Gets the string for a log level.
 *
 * @param[in] log_level
 * @return A null-terminated string for the log level.
 * Example: "ERROR", "WARN", "INFO", etc.
 */
CASS_EXPORT const char*
cass_log_level_string(CassLogLevel log_level);

/***********************************************************************************
 *
 * Inet
 *
 ************************************************************************************/

/**
 * Constructs an inet v4 object.
 *
 * @public @memberof CassInet
 *
 * @param[in] address An address of size CASS_INET_V4_LENGTH
 * @return An inet object.
 */
CASS_EXPORT CassInet
cass_inet_init_v4(const cass_uint8_t* address);

/**
 * Constructs an inet v6 object.
 *
 * @public @memberof CassInet
 *
 * @param[in] address An address of size CASS_INET_V6_LENGTH
 * @return An inet object.
 */
CASS_EXPORT CassInet
cass_inet_init_v6(const cass_uint8_t* address);

/**
 * Returns a null-terminated string for the specified inet.
 *
 * @public @memberof CassInet
 *
 * @param[in] inet
 * @param[out] output A null-terminated string of length CASS_INET_STRING_LENGTH.
 */
CASS_EXPORT void
cass_inet_string(CassInet inet,
                 char* output);

/**
 * Returns an inet for the specified string.
 *
 * Examples: "127.0.0.1" or "::1"
 *
 * @public @memberof CassInet
 *
 * @param[in] str
 * @param[out] output
 */
CASS_EXPORT CassError
cass_inet_from_string(const char* str,
                      CassInet* output);

/**
 * Same as cass_inet_from_string(), but with lengths for string
 * parameters.
 *
 * @public @memberof CassInet
 *
 * @param[in] str
 * @param[in] str_length
 * @param[out] output
 * @return same as cass_inet_from_string()
 *
 * @see cass_inet_from_string()
 */
CASS_EXPORT CassError
cass_inet_from_string_n(const char* str,
                        size_t str_length,
                        CassInet* output);

/***********************************************************************************
 *
 * Date/Time
 *
 ************************************************************************************/

/**
 * Converts a unix timestamp (in seconds) to the Cassandra "date" type. The "date" type
 * represents the number of days since the Epoch (1970-01-01) with the Epoch centered at
 * the value 2^31.
 *
 * @cassandra{2.2+}
 *
 * @param[in] epoch_secs
 * @return the number of days since the date -5877641-06-23
 */
CASS_EXPORT cass_uint32_t
cass_date_from_epoch(cass_int64_t epoch_secs);

/**
 * Converts a unix timestamp (in seconds) to the Cassandra "time" type. The "time" type
 * represents the number of nanoseconds since midnight (range 0 to 86399999999999).
 *
 * @cassandra{2.2+}
 *
 * @param[in] epoch_secs
 * @return nanoseconds since midnight
 */
CASS_EXPORT cass_int64_t
cass_time_from_epoch(cass_int64_t epoch_secs);

/**
 * Combines the Cassandra "date" and "time" types to Epoch time in seconds.
 *
 * @cassandra{2.2+}
 *
 * @param[in] date
 * @param[in] time
 * @return Epoch time in seconds. Negative times are possible if the date
 * occurs before the Epoch (1970-1-1).
 */
CASS_EXPORT cass_int64_t
cass_date_time_to_epoch(cass_uint32_t date,
                        cass_int64_t time);

/***********************************************************************************
 *
 * Allocator
 *
 ************************************************************************************/

/**
 * Set custom allocation functions.
 *
 * <b>Note:</b> This is not thread-safe. The allocation functions must be set
 * before any other library function is called.
 *
 * <b>Default:</b> The C runtime's malloc(), realloc() and free()
 *
 * <b>Important:</b> The C runtime's malloc(), realloc() and free() will be
 * used by libuv when using versions 1.5 or earlier.
 *
 * @param[in] malloc_func
 * @param[in] realloc_func
 * @param[in] free_func
 */
CASS_EXPORT void
cass_alloc_set_functions(CassMallocFunction malloc_func,
                         CassReallocFunction realloc_func,
                         CassFreeFunction free_func);

#ifdef __cplusplus
} /* extern "C" */
#endif

#endif /* __CASS_H_INCLUDED__ */
