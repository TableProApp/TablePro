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
 *   tp_dm_cancel is the one exception: it is safe from another thread while a
 *   call is in flight, which is the only time it does anything.
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

/*
 * expects_rows selects the protocol framing path only. It does not decide what the
 * caller receives: a statement that returns rows anyway still reports its columns
 * and rows rather than an affected count.
 *
 * timeout_millis bounds the wait for the server. Zero waits indefinitely, which is
 * only safe when the caller can cancel.
 */
TpDmResult *tp_dm_execute(
    TpDmConnection *connection,
    const uint8_t *sql,
    size_t sql_length,
    bool expects_rows,
    size_t row_cap,
    uint64_t timeout_millis,
    TpDmError **error_out
);

/*
 * Asks an in-flight statement to stop. Stopping abandons the server's reply
 * mid-message, so the connection is closed and must be treated as disconnected.
 */
void tp_dm_cancel(const TpDmConnection *connection);
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

/* True when the caller stopped the statement, rather than the server or transport failing. */
bool tp_dm_error_is_cancellation(const TpDmError *error);

/*
 * True when the failure closed the connection, so the handle can never serve another
 * statement. A statement the server merely rejected reports false and leaves the
 * connection usable. The caller must reconnect before its next statement.
 */
bool tp_dm_error_is_connection_lost(const TpDmError *error);

#endif /* CDameng_h */
