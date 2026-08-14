#ifndef CDameng_h
#define CDameng_h

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

typedef struct TpDmConnection TpDmConnection;
typedef struct TpDmError TpDmError;
typedef struct TpDmResult TpDmResult;

/*
 * Ownership and lifetime rules:
 * - Input byte pointers must remain valid for their accompanying length until
 *   the function returns.
 * - Connection handles are exclusively owned by the caller, must not be used
 *   concurrently, and must be released exactly once with tp_dm_disconnect.
 * - Result and error handles must be released exactly once with their matching
 *   free function. Byte pointers borrowed from them remain valid only until the
 *   owning handle is released and must never be freed directly.
 * - Non-NULL output pointers must point to writable storage. On failure,
 *   error_out receives an owned error handle when diagnostic text is available.
 * - Passing a dangling handle or an invalid pointer is undefined behavior.
 */
TpDmConnection *tp_dm_connect(
    const uint8_t *host,
    size_t host_length,
    uint16_t port,
    const uint8_t *username,
    size_t username_length,
    const uint8_t *password,
    size_t password_length,
    TpDmError **error_out
);
void tp_dm_disconnect(TpDmConnection *connection);
TpDmResult *tp_dm_execute(
    TpDmConnection *connection,
    const uint8_t *sql,
    size_t sql_length,
    bool expects_rows,
    size_t row_cap,
    TpDmError **error_out
);
bool tp_dm_begin(TpDmConnection *connection, TpDmError **error_out);
bool tp_dm_commit(TpDmConnection *connection, TpDmError **error_out);
bool tp_dm_rollback(TpDmConnection *connection, TpDmError **error_out);
bool tp_dm_ping(TpDmConnection *connection, TpDmError **error_out);

void tp_dm_result_free(TpDmResult *result);
size_t tp_dm_result_column_count(const TpDmResult *result);
size_t tp_dm_result_row_count(const TpDmResult *result);
uint64_t tp_dm_result_rows_affected(const TpDmResult *result);
double tp_dm_result_execution_time(const TpDmResult *result);
bool tp_dm_result_is_truncated(const TpDmResult *result);
const uint8_t *tp_dm_result_column_name(
    const TpDmResult *result,
    size_t column_index,
    size_t *length_out
);
const uint8_t *tp_dm_result_column_type(
    const TpDmResult *result,
    size_t column_index,
    size_t *length_out
);
int32_t tp_dm_result_cell_kind(
    const TpDmResult *result,
    size_t row_index,
    size_t column_index
);
const uint8_t *tp_dm_result_cell_bytes(
    const TpDmResult *result,
    size_t row_index,
    size_t column_index,
    size_t *length_out
);

void tp_dm_error_free(TpDmError *error);
const uint8_t *tp_dm_error_message(const TpDmError *error, size_t *length_out);

#endif /* CDameng_h */
