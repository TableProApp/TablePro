/* Copyright (C) 2018-2022 MariaDB Corporation AB

   This library is free software; you can redistribute it and/or
   modify it under the terms of the GNU Library General Public
   License as published by the Free Software Foundation; either
   version 2 of the License, or (at your option) any later version.
 
   This library is distributed in the hope that it will be useful,
   but WITHOUT ANY WARRANTY; without even the implied warranty of
   MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU
   Library General Public License for more details.
 
   You should have received a copy of the GNU Library General Public
   License along with this library; if not, write to the Free
   Software Foundation, Inc., 51 Franklin Street, Fifth Floor, Boston,
   MA 02111-1301, USA */
#ifndef _mariadb_rpl_h_
#define _mariadb_rpl_h_

#ifdef	__cplusplus
extern "C" {
#endif

#include <stdint.h>
#include <mariadb/ma_io.h>

#define MARIADB_RPL_VERSION 0x0002
#define MARIADB_RPL_REQUIRED_VERSION 0x0002

#define RPL_BINLOG_MAGIC (const uchar*) "\xFE\x62\x69\x6E"
#define RPL_BINLOG_MAGIC_SIZE 4

/* Protocol flags */
#define MARIADB_RPL_BINLOG_DUMP_NON_BLOCK 1
#define MARIADB_RPL_BINLOG_SEND_ANNOTATE_ROWS 2
#define MARIADB_RPL_IGNORE_HEARTBEAT (1 << 17)

#define EVENT_HEADER_OFS 20

#define FL_STMT_END 1

/* GTID flags */ 

/* FL_STANDALONE is set in case there is no terminating COMMIT event. */
#define FL_STANDALONE            0x01

/* FL_GROUP_COMMIT_ID is set when event group is part of a group commit */
#define FL_GROUP_COMMIT_ID       0x02

/* FL_TRANSACTIONAL is set for an event group that can be safely rolled back
    (no MyISAM, eg.).
  */
#define FL_TRANSACTIONAL         0x04
  /*
    FL_ALLOW_PARALLEL reflects the (negation of the) value of
    @@SESSION.skip_parallel_replication at the time of commit.
  */
#define FL_ALLOW_PARALLEL        0x08;
  /*
    FL_WAITED is set if a row lock wait (or other wait) is detected during the
    execution of the transaction.
  */
#define FL_WAITED                0x10
  /* FL_DDL is set for event group containing DDL. */
#define FL_DDL                   0x20
  /* FL_PREPARED_XA is set for XA transaction. */
#define FL_PREPARED_XA           0x40
  /* FL_"COMMITTED or ROLLED-BACK"_XA is set for XA transaction. */
#define FL_COMPLETED_XA          0x80


/* SEMI SYNCHRONOUS REPLICATION */
#define SEMI_SYNC_INDICATOR 0xEF
#define SEMI_SYNC_ACK_REQ   0x01

/* Options */
enum mariadb_rpl_option {
  MARIADB_RPL_FILENAME,       /* Filename and length */
  MARIADB_RPL_START,          /* Start position */
  MARIADB_RPL_SERVER_ID,      /* Server ID */
  MARIADB_RPL_FLAGS,          /* Protocol flags */
  MARIADB_RPL_GTID_CALLBACK,  /* GTID callback function */
  MARIADB_RPL_GTID_DATA,      /* GTID data */
  MARIADB_RPL_BUFFER,
  MARIADB_RPL_VERIFY_CHECKSUM,
  MARIADB_RPL_UNCOMPRESS,
  MARIADB_RPL_HOST,
  MARIADB_RPL_PORT,
  MARIADB_RPL_EXTRACT_VALUES,
  MARIADB_RPL_SEMI_SYNC,
};

/* Event types: From MariaDB Server sql/log_event.h */
enum mariadb_rpl_event {
  UNKNOWN_EVENT= 0,
  START_EVENT_V3= 1,
  QUERY_EVENT= 2,
  STOP_EVENT= 3,
  ROTATE_EVENT= 4,
  INTVAR_EVENT= 5,
  LOAD_EVENT= 6,
  SLAVE_EVENT= 7,
  CREATE_FILE_EVENT= 8,
  APPEND_BLOCK_EVENT= 9,
  EXEC_LOAD_EVENT= 10,
  DELETE_FILE_EVENT= 11,
  NEW_LOAD_EVENT= 12,
  RAND_EVENT= 13,
  USER_VAR_EVENT= 14,
  FORMAT_DESCRIPTION_EVENT= 15,
  XID_EVENT= 16,
  BEGIN_LOAD_QUERY_EVENT= 17,
  EXECUTE_LOAD_QUERY_EVENT= 18,
  TABLE_MAP_EVENT = 19,

  PRE_GA_WRITE_ROWS_EVENT = 20, /* deprecated */
  PRE_GA_UPDATE_ROWS_EVENT = 21, /* deprecated */
  PRE_GA_DELETE_ROWS_EVENT = 22, /* deprecated */

  WRITE_ROWS_EVENT_V1 = 23,
  UPDATE_ROWS_EVENT_V1 = 24,
  DELETE_ROWS_EVENT_V1 = 25,
  INCIDENT_EVENT= 26,
  HEARTBEAT_LOG_EVENT= 27,
  IGNORABLE_LOG_EVENT= 28,
  ROWS_QUERY_LOG_EVENT= 29,
  WRITE_ROWS_EVENT = 30,
  UPDATE_ROWS_EVENT = 31,
  DELETE_ROWS_EVENT = 32,
  GTID_LOG_EVENT= 33,
  ANONYMOUS_GTID_LOG_EVENT= 34,
  PREVIOUS_GTIDS_LOG_EVENT= 35,
  TRANSACTION_CONTEXT_EVENT= 36,
  VIEW_CHANGE_EVENT= 37,
  XA_PREPARE_LOG_EVENT= 38,
  PARTIAL_UPDATE_ROWS_EVENT = 39,

  /*
    Add new events here - right above this comment!
    Existing events (except ENUM_END_EVENT) should never change their numbers
  */

  /* New MySQL events are to be added right above this comment */
  MYSQL_EVENTS_END,

  MARIA_EVENTS_BEGIN= 160,
  ANNOTATE_ROWS_EVENT= 160,
  BINLOG_CHECKPOINT_EVENT= 161,
  GTID_EVENT= 162,
  GTID_LIST_EVENT= 163,
  START_ENCRYPTION_EVENT= 164,
  QUERY_COMPRESSED_EVENT = 165,
  WRITE_ROWS_COMPRESSED_EVENT_V1 = 166,
  UPDATE_ROWS_COMPRESSED_EVENT_V1 = 167,
  DELETE_ROWS_COMPRESSED_EVENT_V1 = 168,
  WRITE_ROWS_COMPRESSED_EVENT = 169,
  UPDATE_ROWS_COMPRESSED_EVENT = 170,
  DELETE_ROWS_COMPRESSED_EVENT = 171,

  /* Add new MariaDB events here - right above this comment!  */

  ENUM_END_EVENT /* end marker */
};

/* ROWS_EVENT flags */

#define STMT_END_F                    0x01
#define NO_FOREIGN_KEY_CHECKS_F       0x02
#define RELAXED_UNIQUE_KEY_CHECKS_F   0x04
#define COMPLETE_ROWS_F               0x08
#define NO_CHECK_CONSTRAINT_CHECKS_F  0x80


enum mariadb_rpl_status_code {
  Q_FLAGS2_CODE= 0x00,
  Q_SQL_MODE_CODE= 0x01,
  Q_CATALOG_CODE= 0x02,
  Q_AUTO_INCREMENT_CODE= 0x03,
  Q_CHARSET_CODE= 0x04,
  Q_TIMEZONE_CODE= 0x05,
  Q_CATALOG_NZ_CODE= 0x06,
  Q_LC_TIME_NAMES_CODE= 0x07,
  Q_CHARSET_DATABASE_CODE= 0x08,
  Q_TABLE_MAP_FOR_UPDATE_CODE= 0x09,
  Q_MASTER_DATA_WRITTEN_CODE= 0x0A,
  Q_INVOKERS_CODE= 0x0B,
  Q_UPDATED_DB_NAMES_CODE= 0x0C,
  Q_MICROSECONDS_CODE= 0x0D,
  Q_COMMIT_TS_CODE= 0x0E,  /* unused */
  Q_COMMIT_TS2_CODE= 0x0F, /* unused */
  Q_EXPLICIT_DEFAULTS_FOR_TIMESTAMP_CODE= 0x10,
  Q_DDL_LOGGED_WITH_XID_CODE= 0x11,
  Q_DEFAULT_COLLATION_FOR_UTF8_CODE= 0x12,
  Q_SQL_REQUIRE_PRIMARY_KEY_CODE= 0x13,
  Q_DEFAULT_TABLE_ENCRYPTION_CODE= 0x14,
  Q_HRNOW= 128,  /* second part: 3 bytes */
  Q_XID= 129    /* xid: 8 bytes */
};

#ifdef DEFAULT_CHARSET
#undef DEFAULT_CHARSET
#endif

enum opt_metadata_field_type
{
  SIGNEDNESS = 1,
  DEFAULT_CHARSET,
  COLUMN_CHARSET,
  COLUMN_NAME,
  SET_STR_VALUE,
  ENUM_STR_VALUE,
  GEOMETRY_TYPE, 
  SIMPLE_PRIMARY_KEY,
  PRIMARY_KEY_WITH_PREFIX,
  ENUM_AND_SET_DEFAULT_CHARSET,
  ENUM_AND_SET_COLUMN_CHARSET
};

/* QFLAGS2 codes */
#define OPTION_AUTO_IS_NULL                   0x00040000
#define OPTION_NOT_AUTOCOMMIT                 0x00080000
#define OPTION_NO_FOREIGN_KEY_CHECKS          0x04000000
#define OPTION_RELAXED_UNIQUE_CHECKS          0x08000000

/* SQL modes */
#define MODE_REAL_AS_FLOAT                    0x00000001
#define MODE_PIPES_AS_CONCAT                  0x00000002
#define MODE_ANSI_QUOTES                      0x00000004
#define MODE_IGNORE_SPACE                     0x00000008
#define MODE_NOT_USED                         0x00000010
#define MODE_ONLY_FULL_GROUP_BY               0x00000020
#define MODE_NO_UNSIGNED_SUBTRACTION          0x00000040
#define MODE_NO_DIR_IN_CREATE                 0x00000080
#define MODE_POSTGRESQL                       0x00000100
#define MODE_ORACLE                           0x00000200
#define MODE_MSSQL                            0x00000400
#define MODE_DB2                              0x00000800
#define MODE_MAXDB                            0x00001000
#define MODE_NO_KEY_OPTIONS                   0x00002000
#define MODE_NO_TABLE_OPTIONS                 0x00004000
#define MODE_NO_FIELD_OPTIONS                 0x00008000
#define MODE_MYSQL323                         0x00010000
#define MODE_MYSQL40                          0x00020000
#define MODE_ANSI                             0x00040000
#define MODE_NO_AUTO_VALUE_ON_ZERO            0x00080000
#define MODE_NO_BACKSLASH_ESCAPES             0x00100000
#define MODE_STRICT_TRANS_TABLES              0x00200000
#define MODE_STRICT_ALL_TABLES                0x00400000
#define MODE_NO_ZERO_IN_DATE                  0x00800000
#define MODE_NO_ZERO_DATE                     0x01000000
#define MODE_INVALID_DATES                    0x02000000
#define MODE_ERROR_FOR_DIVISION_BY_ZERO       0x04000000
#define MODE_TRADITIONAL                      0x08000000
#define MODE_NO_AUTO_CREATE_USER              0x10000000
#define MODE_HIGH_NOT_PRECEDENCE              0x20000000
#define MODE_NO_ENGINE_SUBSTITUTION           0x40000000
#define MODE_PAD_CHAR_TO_FULL_LENGTH          0x80000000

/* Log Event flags */

/* used in FOMRAT_DESCRIPTION_EVENT. Indicates if it
   is the active binary log.
   Note: When reading data via COM_BINLOG_DUMP this
         flag is never set.
*/ 
#define LOG_EVENT_BINLOG_IN_USE_F           0x0001

/* Looks like this flag is no longer in use */
#define LOG_EVENT_FORCED_ROTATE_F           0x0002

/* Log entry depends on thread, e.g. when using user variables
   or temporary tables */
#define LOG_EVENT_THREAD_SPECIFIC_F         0x0004

/* Indicates that the USE command can be suppressed before
   executing a statement: e.g. DRIP SCHEMA  */
#define LOG_EVENT_SUPPRESS_USE_F            0x0008

/* ??? */
#define LOG_EVENT_UPDATE_TABLE_MAP_F        0x0010

/* Artifical event */
#define LOG_EVENT_ARTIFICIAL_F              0x0020

/* ??? */
#define LOG_EVENT_RELAY_LOG_F               0x0040

/* If an event is not supported, and LOG_EVENT_IGNORABLE_F was not
   set, an error will be reported. */
#define LOG_EVENT_IGNORABLE_F               0x0080

/* ??? */
#define LOG_EVENT_NO_FILTER_F               0x0100

/* ?? */
#define LOG_EVENT_MTS_ISOLATE_F             0x0200

/* if session variable @@skip_repliation was set, this flag will be
   reported for events which should be skipped. */
#define LOG_EVENT_SKIP_REPLICATION_F        0x8000

typedef struct {
  char *str;
  size_t length;
} MARIADB_STRING;

enum mariadb_row_event_type {
  WRITE_ROWS= 0,
  UPDATE_ROWS= 1,
  DELETE_ROWS= 2
};

/* Global transaction id */
typedef struct st_mariadb_gtid {
  unsigned int domain_id;
  unsigned int server_id;
  unsigned long long sequence_nr;
} MARIADB_GTID;


/* Generic replication handle */
typedef struct st_mariadb_rpl {
  unsigned int version;
  MYSQL *mysql;
  char *filename;
  uint32_t filename_length;
  uint32_t server_id;
  unsigned long start_position;
  uint16_t flags;
  uint8_t fd_header_len; /* header len from last format description event */
  uint8_t use_checksum;
  uint8_t artificial_checksum;
  uint8_t verify_checksum;
  uint8_t post_header_len[ENUM_END_EVENT];
  MA_FILE *fp;
  uint32_t error_no;
  char error_msg[MYSQL_ERRMSG_SIZE];
  uint8_t uncompress;
  char *host;
  uint32_t port;
  uint8_t extract_values;
  char nonce[12];
  uint8_t encrypted;
  uint8_t is_semi_sync;
}MARIADB_RPL;

typedef struct st_mariadb_rpl_value {
  enum enum_field_types field_type;
  uint8_t is_null;
  uint8_t is_signed;
  union {
    int64_t ll;
    uint64_t ull;
    float f;
    double d;
    MYSQL_TIME tm;
    MARIADB_STRING str;
  } val;
} MARIADB_RPL_VALUE;

typedef struct st_rpl_mariadb_row {
  uint32_t column_count;
  MARIADB_RPL_VALUE *columns;
  struct st_rpl_mariadb_row *next;
} MARIADB_RPL_ROW;

/* Event header */
struct st_mariadb_rpl_rotate_event {
  unsigned long long position;
  MARIADB_STRING filename;
};

struct st_mariadb_rpl_query_event {
  uint32_t thread_id;
  uint32_t seconds;
  MARIADB_STRING database;
  uint32_t errornr;
  MARIADB_STRING status;
  MARIADB_STRING statement;
};

struct st_mariadb_rpl_previous_gtid_event {
  MARIADB_CONST_DATA content;
};

struct st_mariadb_rpl_gtid_list_event {
  uint32_t gtid_cnt;
  MARIADB_GTID *gtid;
};

struct st_mariadb_rpl_format_description_event
{
  uint16_t format;
  char *server_version;
  uint32_t timestamp;
  uint8_t header_len;
  MARIADB_STRING post_header_lengths;
};

struct st_mariadb_rpl_checkpoint_event {
  MARIADB_STRING filename;
};

struct st_mariadb_rpl_xid_event {
  uint64_t transaction_nr;
};

struct st_mariadb_rpl_gtid_event {
  uint64_t sequence_nr;
  uint32_t domain_id;
  uint8_t flags;
  uint64_t commit_id;
  uint32_t format_id;
  uint8_t gtrid_len;
  uint8_t bqual_len;
  MARIADB_STRING xid;
};

struct st_mariadb_rpl_annotate_rows_event {
  MARIADB_STRING statement;
};

struct st_mariadb_rpl_table_map_event {
  unsigned long long table_id;
  MARIADB_STRING database;
  MARIADB_STRING table;
  uint32_t column_count;
  MARIADB_STRING column_types;
  MARIADB_STRING metadata;
  unsigned char *null_indicator;
  unsigned char *signed_indicator;
  MARIADB_CONST_DATA column_names;
  MARIADB_CONST_DATA geometry_types;
  uint32_t default_charset;
  MARIADB_CONST_DATA column_charsets;
  MARIADB_CONST_DATA simple_primary_keys;
  MARIADB_CONST_DATA prefixed_primary_keys;
  MARIADB_CONST_DATA set_values;
  MARIADB_CONST_DATA enum_values;
  uint8_t enum_set_default_charset;
  MARIADB_CONST_DATA enum_set_column_charsets;
};

struct st_mariadb_rpl_rand_event {
  unsigned long long first_seed;
  unsigned long long second_seed;
};

struct st_mariadb_rpl_intvar_event {
  unsigned long long value;
  uint8_t type;
};

struct st_mariadb_begin_load_query_event {
  uint32_t file_id;
  unsigned char *data;
};

struct st_mariadb_start_encryption_event {
  uint8_t scheme;
  uint32_t key_version;
  char nonce[12];
};

struct st_mariadb_execute_load_query_event {
  uint32_t thread_id;
  uint32_t execution_time;
  MARIADB_STRING schema;
  uint16_t error_code;
  uint32_t file_id;
  uint32_t ofs1;
  uint32_t ofs2;
  uint8_t duplicate_flag;
  MARIADB_STRING status_vars;
  MARIADB_STRING statement;
};

struct st_mariadb_rpl_uservar_event {
  MARIADB_STRING name;
  uint8_t is_null;
  uint8_t type;
  uint32_t charset_nr;
  MARIADB_STRING value;
  uint8_t flags;
};

struct st_mariadb_rpl_rows_event {
  enum mariadb_row_event_type type;
  uint64_t table_id;
  uint16_t flags;
  uint32_t column_count;
  unsigned char *column_bitmap;
  unsigned char *column_update_bitmap;
  unsigned char *null_bitmap;
  size_t row_data_size;
  void *row_data;
  size_t extra_data_size;
  void *extra_data;
  uint8_t compressed;
  uint32_t row_count;
};

struct st_mariadb_rpl_heartbeat_event {
  MARIADB_STRING filename;
};

struct st_mariadb_rpl_xa_prepare_log_event {
  uint8_t one_phase;
  uint32_t format_id;
  uint32_t gtrid_len;
  uint32_t bqual_len;
  MARIADB_STRING xid;
};

struct st_mariadb_gtid_log_event {
  uint8_t commit_flag;
  char    source_id[16];
  uint64_t sequence_nr;
};

typedef struct st_mariadb_rpl_event
{
  /* common header */
  MA_MEM_ROOT memroot;
  unsigned char *raw_data;
  size_t raw_data_size;
  size_t raw_data_ofs;
  unsigned int checksum;
  char ok;
  enum mariadb_rpl_event event_type;
  unsigned int timestamp;
  unsigned int server_id;
  unsigned int event_length;
  unsigned int next_event_pos;
  unsigned short flags;
  /****************/
  union {
    struct st_mariadb_rpl_rotate_event rotate;
    struct st_mariadb_rpl_query_event query;
    struct st_mariadb_rpl_format_description_event format_description;
    struct st_mariadb_rpl_gtid_list_event gtid_list;
    struct st_mariadb_rpl_checkpoint_event checkpoint;
    struct st_mariadb_rpl_xid_event xid;
    struct st_mariadb_rpl_gtid_event gtid;
    struct st_mariadb_rpl_annotate_rows_event annotate_rows;
    struct st_mariadb_rpl_table_map_event table_map;
    struct st_mariadb_rpl_rand_event rand;
    struct st_mariadb_rpl_intvar_event intvar;
    struct st_mariadb_rpl_uservar_event uservar;
    struct st_mariadb_rpl_rows_event rows;
    struct st_mariadb_rpl_heartbeat_event heartbeat;
    struct st_mariadb_rpl_xa_prepare_log_event xa_prepare_log;
    struct st_mariadb_begin_load_query_event begin_load_query;
    struct st_mariadb_execute_load_query_event execute_load_query;
    struct st_mariadb_gtid_log_event gtid_log;
    struct st_mariadb_start_encryption_event start_encryption;
    struct st_mariadb_rpl_previous_gtid_event previous_gtid;
  } event;
  /* Added in C/C 3.3.0 */
  uint8_t is_semi_sync;
  uint8_t semi_sync_flags;
  /* Added in C/C 3.3.5 */
  MARIADB_RPL *rpl;
} MARIADB_RPL_EVENT;

/* compression uses myisampack format */
#define myisam_uint1korr(B) ((uint8_t)(*B))
#define myisam_sint1korr(B) ((int8_t)(*B))
#define myisam_uint2korr(B)\
((uint16_t)(((uint16_t)(((const uchar*)(B))[1])) | ((uint16_t) (((const uchar*) (B))[0]) << 8)))
#define myisam_sint2korr(B)\
((int16_t)(((int16_t)(((const uchar*)(B))[1])) | ((int16_t) (((const uchar*) (B))[0]) << 8)))
#define myisam_uint3korr(B)\
((uint32_t)(((uint32_t)(((const uchar*)(B))[2])) |\
(((uint32_t)(((const uchar*)(B))[1])) << 8) |\
(((uint32_t)(((const uchar*)(B))[0])) << 16)))
#define myisam_sint3korr(B)\
((int32_t)(((int32_t)(((const uchar*)(B))[2])) |\
(((int32_t)(((const uchar*)(B))[1])) << 8) |\
(((int32_t)(((const uchar*)(B))[0])) << 16)))
#define myisam_uint4korr(B)\
((uint32_t)(((uint32_t)(((const uchar*)(B))[3])) |\
(((uint32_t)(((const uchar*)(B))[2])) << 8) |\
(((uint32_t)(((const uchar*) (B))[1])) << 16) |\
(((uint32_t)(((const uchar*) (B))[0])) << 24)))
#define myisam_sint4korr(B)\
((int32_t)(((int32_t)(((const uchar*)(B))[3])) |\
(((int32_t)(((const uchar*)(B))[2])) << 8) |\
(((int32_t)(((const uchar*) (B))[1])) << 16) |\
(((int32_t)(((const uchar*) (B))[0])) << 24)))
#define mi_uint5korr(B)\
((uint64_t)(((uint32_t) (((const uchar*) (B))[4])) |\
(((uint32_t) (((const uchar*) (B))[3])) << 8) |\
(((uint32_t) (((const uchar*) (B))[2])) << 16) |\
(((uint32_t) (((const uchar*) (B))[1])) << 24)) |\
(((uint64_t) (((const uchar*) (B))[0])) << 32))

#define RPL_SAFEGUARD(rpl, event, condition) \
if (!(condition))\
{\
  my_set_error((rpl)->mysql, CR_BINLOG_ERROR, SQLSTATE_UNKNOWN, 0,\
                (rpl)->filename_length, (rpl)->filename,\
                (rpl)->start_position,\
                "Packet corrupted");\
  mariadb_free_rpl_event((event));\
  return 0;\
}

#define mariadb_rpl_init(a) mariadb_rpl_init_ex((a), MARIADB_RPL_VERSION)
#define rpl_clear_error(rpl)\
(rpl)->error_no= (rpl)->error_msg[0]= 0

#define IS_ROW_VERSION2(a)\
  ((a) == WRITE_ROWS_EVENT  || (a) == UPDATE_ROWS_EVENT || \
   (a) == DELETE_ROWS_EVENT || (a) == WRITE_ROWS_COMPRESSED_EVENT ||\
   (a) == UPDATE_ROWS_COMPRESSED_EVENT || (a) == DELETE_ROWS_COMPRESSED_EVENT)

#define IS_ROW_EVENT(a)\
((a)->event_type == WRITE_ROWS_COMPRESSED_EVENT_V1 ||\
(a)->event_type == UPDATE_ROWS_COMPRESSED_EVENT_V1 ||\
(a)->event_type == DELETE_ROWS_COMPRESSED_EVENT_V1 ||\
(a)->event_type == WRITE_ROWS_EVENT_V1 ||\
(a)->event_type == UPDATE_ROWS_EVENT_V1 ||\
(a)->event_type == DELETE_ROWS_EVENT_V1 ||\
(a)->event_type == WRITE_ROWS_EVENT ||\
(a)->event_type == UPDATE_ROWS_EVENT ||\
(a)->event_type == DELETE_ROWS_EVENT)

/* Function prototypes */
MARIADB_RPL * STDCALL mariadb_rpl_init_ex(MYSQL *mysql, unsigned int version);
const char * STDCALL mariadb_rpl_error(MARIADB_RPL *rpl);
uint32_t STDCALL mariadb_rpl_errno(MARIADB_RPL *rpl);

int STDCALL mariadb_rpl_optionsv(MARIADB_RPL *rpl, enum mariadb_rpl_option, ...);
int STDCALL mariadb_rpl_get_optionsv(MARIADB_RPL *rpl, enum mariadb_rpl_option, ...);

int STDCALL mariadb_rpl_open(MARIADB_RPL *rpl);
void STDCALL mariadb_rpl_close(MARIADB_RPL *rpl);
MARIADB_RPL_EVENT * STDCALL mariadb_rpl_fetch(MARIADB_RPL *rpl, MARIADB_RPL_EVENT *event);
void STDCALL mariadb_free_rpl_event(MARIADB_RPL_EVENT *event);

MARIADB_RPL_ROW * STDCALL
mariadb_rpl_extract_rows(MARIADB_RPL *rpl,
                         MARIADB_RPL_EVENT *tm_event,
                         MARIADB_RPL_EVENT *row_event);

#ifdef	__cplusplus
}
#endif
#endif
