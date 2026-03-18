/************************************************************************
  
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
   MA 02111-1301, USA 

   Part of this code includes code from PHP's mysqlnd extension
   (written by Andrey Hristov, Georg Richter and Ulf Wendel), freely
   available from http://www.php.net/software

*************************************************************************/

#define MYSQL_NO_DATA 100
#define MYSQL_DATA_TRUNCATED 101
#define MYSQL_DEFAULT_PREFETCH_ROWS (unsigned long) 1

/* Bind flags */
#define MADB_BIND_DUMMY 1

#define MARIADB_STMT_BULK_SUPPORTED(stmt)\
  ((stmt)->mysql && \
  (!((stmt)->mysql->server_capabilities & CLIENT_MYSQL) &&\
    ((stmt)->mysql->extension->mariadb_server_capabilities & \
    (MARIADB_CLIENT_STMT_BULK_OPERATIONS >> 32))))

#define MARIADB_STMT_BULK_UNIT_RESULTS_SUPPORTED(stmt)\
  ((stmt)->mysql && \
  (!((stmt)->mysql->server_capabilities & CLIENT_MYSQL) &&\
    ((stmt)->mysql->extension->mariadb_client_flag & \
    (MARIADB_CLIENT_BULK_UNIT_RESULTS >> 32))))

#define CLEAR_CLIENT_STMT_ERROR(a) \
do { \
  (a)->last_errno= 0;\
  strcpy((a)->sqlstate, "00000");\
  (a)->last_error[0]= 0;\
} while (0)

#define MYSQL_PS_SKIP_RESULT_W_LEN  -1
#define MYSQL_PS_SKIP_RESULT_STR    -2
#define STMT_ID_LENGTH 4


typedef struct st_mysql_stmt MYSQL_STMT;

typedef MYSQL_RES* (*mysql_stmt_use_or_store_func)(MYSQL_STMT *);

enum enum_stmt_attr_type
{
  STMT_ATTR_UPDATE_MAX_LENGTH,
  STMT_ATTR_CURSOR_TYPE,
  STMT_ATTR_PREFETCH_ROWS,

  /* MariaDB only */
  STMT_ATTR_PREBIND_PARAMS=200,
  STMT_ATTR_ARRAY_SIZE,
  STMT_ATTR_ROW_SIZE,
  STMT_ATTR_STATE,
  STMT_ATTR_CB_USER_DATA,
  STMT_ATTR_CB_PARAM,
  STMT_ATTR_CB_RESULT,
  STMT_ATTR_SQL_STATEMENT
};

enum enum_cursor_type
{
  CURSOR_TYPE_NO_CURSOR= 0,
  CURSOR_TYPE_READ_ONLY= 1,
  CURSOR_TYPE_FOR_UPDATE= 2,
  CURSOR_TYPE_SCROLLABLE= 4
};

enum enum_indicator_type
{
  STMT_INDICATOR_NTS=-1,
  STMT_INDICATOR_NONE=0,
  STMT_INDICATOR_NULL=1,
  STMT_INDICATOR_DEFAULT=2,
  STMT_INDICATOR_IGNORE=3,
  STMT_INDICATOR_IGNORE_ROW=4
};

/*
  bulk PS flags
*/
#define STMT_BULK_FLAG_CLIENT_SEND_TYPES 128
#define STMT_BULK_FLAG_SEND_UNIT_RESULTS 64

typedef enum mysql_stmt_state
{
  MYSQL_STMT_INITTED = 0,
  MYSQL_STMT_PREPARED,
  MYSQL_STMT_EXECUTED,
  MYSQL_STMT_WAITING_USE_OR_STORE,
  MYSQL_STMT_USE_OR_STORE_CALLED,
  MYSQL_STMT_USER_FETCHING, /* fetch_row_buff or fetch_row_unbuf */
  MYSQL_STMT_FETCH_DONE
} enum_mysqlnd_stmt_state;

typedef struct st_mysql_bind
{
  unsigned long  *length;          /* output length pointer */
  my_bool        *is_null;         /* Pointer to null indicator */
  void           *buffer;          /* buffer to get/put data */
  /* set this if you want to track data truncations happened during fetch */
  my_bool        *error;
  union {
    unsigned char *row_ptr;        /* for the current data position */
    char *indicator;               /* indicator variable */
  } u;
  void (*store_param_func)(NET *net, struct st_mysql_bind *param);
  void (*fetch_result)(struct st_mysql_bind *, MYSQL_FIELD *,
                       unsigned char **row);
  void (*skip_result)(struct st_mysql_bind *, MYSQL_FIELD *,
          unsigned char **row);
  /* output buffer length, must be set when fetching str/binary */
  unsigned long  buffer_length;
  unsigned long  offset;           /* offset position for char/binary fetch */
  unsigned long  length_value;     /* Used if length is 0 */
  unsigned int   flags;            /* special flags, e.g. for dummy bind  */
  unsigned int   pack_length;      /* Internal length for packed data */
  enum enum_field_types buffer_type;  /* buffer type */
  my_bool        error_value;      /* used if error is 0 */
  my_bool        is_unsigned;      /* set if integer type is unsigned */
  my_bool        long_data_used;   /* If used with mysql_send_long_data */
  my_bool        is_null_value;    /* Used if is_null is 0 */
  void           *extension;
} MYSQL_BIND;

typedef struct st_mysqlnd_upsert_result
{
  unsigned int  warning_count;
  unsigned int  server_status;
  unsigned long long affected_rows;
  unsigned long long last_insert_id;
} mysql_upsert_status;

typedef struct st_mysql_cmd_buffer
{
  unsigned char   *buffer;
  size_t     length;
} MYSQL_CMD_BUFFER;

typedef struct st_mysql_error_info
{
  unsigned int error_no;
  char error[MYSQL_ERRMSG_SIZE+1];
  char sqlstate[SQLSTATE_LENGTH + 1];
} mysql_error_info;

typedef int  (*mysql_stmt_fetch_row_func)(MYSQL_STMT *stmt, unsigned char **row);
typedef void (*ps_result_callback)(void *data, unsigned int column, unsigned char **row);
typedef my_bool (*ps_param_callback)(void *data, MYSQL_BIND *bind, unsigned int row_nr);

struct st_mysql_stmt
{
  MA_MEM_ROOT              mem_root;
  MYSQL                    *mysql;
  unsigned long            stmt_id;
  unsigned long            flags;/* cursor is set here */
  enum_mysqlnd_stmt_state  state;
  MYSQL_FIELD              *fields;
  unsigned int             field_count;
  unsigned int             param_count;
  unsigned char            send_types_to_server;
  MYSQL_BIND               *params;
  MYSQL_BIND               *bind;
  MYSQL_DATA               result;  /* we don't use mysqlnd's result set logic */
  MYSQL_ROWS               *result_cursor;
  my_bool                  bind_result_done;
  my_bool                  bind_param_done;

  mysql_upsert_status      upsert_status;

  unsigned int last_errno;
  char last_error[MYSQL_ERRMSG_SIZE+1];
  char sqlstate[SQLSTATE_LENGTH + 1];

  my_bool                  update_max_length;
  unsigned long            prefetch_rows;
  LIST                     list;

  my_bool                  cursor_exists;

  void                     *extension;
  mysql_stmt_fetch_row_func fetch_row_func;
  unsigned int             execute_count;/* count how many times the stmt was executed */
  mysql_stmt_use_or_store_func default_rset_handler;
  unsigned char            *request_buffer;
  unsigned int             array_size;
  size_t row_size;
  unsigned int prebind_params;
  void *user_data;
  ps_result_callback result_callback;
  ps_param_callback param_callback;
  size_t request_length;
  MARIADB_CONST_STRING sql;
};

typedef void (*ps_field_fetch_func)(MYSQL_BIND *r_param, const MYSQL_FIELD * field, unsigned char **row);
typedef struct st_mysql_perm_bind {
  ps_field_fetch_func func;
  /* should be signed int */
  int pack_len;
  unsigned long max_len;
} MYSQL_PS_CONVERSION;

extern MYSQL_PS_CONVERSION mysql_ps_fetch_functions[MYSQL_TYPE_GEOMETRY + 1];
unsigned long ma_net_safe_read(MYSQL *mysql);
void mysql_init_ps_subsystem(void);
unsigned long net_field_length(unsigned char **packet);
int ma_simple_command(MYSQL *mysql,enum enum_server_command command, const char *arg,
          	       size_t length, my_bool skipp_check, void *opt_arg);
void stmt_set_error(MYSQL_STMT *stmt,
                  unsigned int error_nr,
                  const char *sqlstate,
                  const char *format,
                  ...);
/*
 *  function prototypes
 */
MYSQL_STMT * STDCALL mysql_stmt_init(MYSQL *mysql);
int STDCALL mysql_stmt_prepare(MYSQL_STMT *stmt, const char *query, unsigned long length);
int STDCALL mysql_stmt_execute(MYSQL_STMT *stmt);
int STDCALL mysql_stmt_fetch(MYSQL_STMT *stmt);
int STDCALL mysql_stmt_fetch_column(MYSQL_STMT *stmt, MYSQL_BIND *bind_arg, unsigned int column, unsigned long offset);
int STDCALL mysql_stmt_store_result(MYSQL_STMT *stmt);
unsigned long STDCALL mysql_stmt_param_count(MYSQL_STMT * stmt);
my_bool STDCALL mysql_stmt_attr_set(MYSQL_STMT *stmt, enum enum_stmt_attr_type attr_type, const void *attr);
my_bool STDCALL mysql_stmt_attr_get(MYSQL_STMT *stmt, enum enum_stmt_attr_type attr_type, void *attr);
my_bool STDCALL mysql_stmt_bind_param(MYSQL_STMT * stmt, MYSQL_BIND * bnd);
my_bool STDCALL mysql_stmt_bind_result(MYSQL_STMT * stmt, MYSQL_BIND * bnd);
my_bool STDCALL mysql_stmt_close(MYSQL_STMT * stmt);
my_bool STDCALL mysql_stmt_reset(MYSQL_STMT * stmt);
my_bool STDCALL mysql_stmt_free_result(MYSQL_STMT *stmt);
my_bool STDCALL mysql_stmt_send_long_data(MYSQL_STMT *stmt, unsigned int param_number, const char *data, unsigned long length);
MYSQL_RES *STDCALL mysql_stmt_result_metadata(MYSQL_STMT *stmt);
MYSQL_RES *STDCALL mysql_stmt_param_metadata(MYSQL_STMT *stmt);
unsigned int STDCALL mysql_stmt_errno(MYSQL_STMT * stmt);
const char *STDCALL mysql_stmt_error(MYSQL_STMT * stmt);
const char *STDCALL mysql_stmt_sqlstate(MYSQL_STMT * stmt);
MYSQL_ROW_OFFSET STDCALL mysql_stmt_row_seek(MYSQL_STMT *stmt, MYSQL_ROW_OFFSET offset);
MYSQL_ROW_OFFSET STDCALL mysql_stmt_row_tell(MYSQL_STMT *stmt);
void STDCALL mysql_stmt_data_seek(MYSQL_STMT *stmt, unsigned long long offset);
unsigned long long STDCALL mysql_stmt_num_rows(MYSQL_STMT *stmt);
unsigned long long STDCALL mysql_stmt_affected_rows(MYSQL_STMT *stmt);
unsigned long long STDCALL mysql_stmt_insert_id(MYSQL_STMT *stmt);
unsigned int STDCALL mysql_stmt_field_count(MYSQL_STMT *stmt);
int STDCALL mysql_stmt_next_result(MYSQL_STMT *stmt);
my_bool STDCALL mysql_stmt_more_results(MYSQL_STMT *stmt);
int STDCALL mariadb_stmt_execute_direct(MYSQL_STMT *stmt, const char *stmt_str, size_t length);
MYSQL_FIELD * STDCALL mariadb_stmt_fetch_fields(MYSQL_STMT *stmt);
