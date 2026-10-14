// Safety contracts for the exported C ABI are documented in CDameng.h, next to
// the declarations consumed by Swift.
#![allow(clippy::missing_safety_doc)]

use std::panic::{catch_unwind, AssertUnwindSafe};
use std::ptr;
use std::slice;
use std::str;
use std::sync::Arc;
use std::time::Instant;

use dameng::{Client, Interrupt};
use dameng_types::encoding::ServerEncoding;
use dameng_types::{DmValue, DmValueType};

const MAX_HOST_BYTES: usize = 1_024;
const MAX_CREDENTIAL_BYTES: usize = 4_096;
const MAX_SQL_BYTES: usize = 16 * 1_024 * 1_024;

pub struct TpDmConnection {
    client: Option<Client>,
    /// Kept beside the client rather than inside it: an in-flight statement moves the
    /// client out of this handle, and `tp_dm_cancel` still has to reach the read loop.
    interrupt: Arc<Interrupt>,
}

pub struct TpDmError {
    message: Vec<u8>,
    cancelled: bool,
    /// The failure left the connection closed rather than merely rejecting the statement.
    /// Swift needs this to tell "the server refused this SQL" from "reconnect before the
    /// next one", which the message text cannot express.
    connection_lost: bool,
}

pub struct TpDmResult {
    columns: Vec<TpDmColumn>,
    rows: Vec<Vec<TpDmCell>>,
    rows_affected: u64,
    execution_time_seconds: f64,
    is_truncated: bool,
}

struct TpDmColumn {
    name: Vec<u8>,
    type_name: Vec<u8>,
}

enum TpDmCell {
    Null,
    Text(Vec<u8>),
    Bytes(Vec<u8>),
}

fn set_error(error_out: *mut *mut TpDmError, message: impl Into<String>) {
    store_error(error_out, message.into(), false, false);
}

/// The handle outlived its client, which an earlier failure disposed. Reported as lost so
/// the caller reconnects instead of retrying against a handle that can never serve again.
fn set_closed_error(error_out: *mut *mut TpDmError, message: impl Into<String>) {
    store_error(error_out, message.into(), false, true);
}

/// Preserves whether the failure was a caller-requested stop, which Swift reports as a
/// cancellation rather than as a query error, and whether it closed the connection, which
/// is the same classification `dispose` acts on.
fn set_driver_error(error_out: *mut *mut TpDmError, error: &dameng::Error) {
    store_error(
        error_out,
        error.to_string(),
        is_cancellation(error),
        !is_recoverable(error),
    );
}

fn store_error(
    error_out: *mut *mut TpDmError,
    message: String,
    cancelled: bool,
    connection_lost: bool,
) {
    if error_out.is_null() {
        return;
    }
    let error = Box::new(TpDmError {
        message: message.into_bytes(),
        cancelled,
        connection_lost,
    });
    unsafe {
        *error_out = Box::into_raw(error);
    }
}

fn clear_error(error_out: *mut *mut TpDmError) {
    if error_out.is_null() {
        return;
    }
    unsafe {
        *error_out = ptr::null_mut();
    }
}

fn panic_message(payload: Box<dyn std::any::Any + Send>) -> String {
    if let Some(message) = payload.downcast_ref::<String>() {
        return message.clone();
    }
    if let Some(message) = payload.downcast_ref::<&str>() {
        return (*message).to_string();
    }
    "Dameng transport panicked".to_string()
}

unsafe fn required_string(
    bytes: *const u8,
    length: usize,
    maximum: usize,
    field: &str,
) -> Result<String, String> {
    if bytes.is_null() {
        return Err(format!("{field} is missing"));
    }
    if length == 0 || length > maximum {
        return Err(format!("{field} length is invalid"));
    }
    let value = slice::from_raw_parts(bytes, length);
    str::from_utf8(value)
        .map(str::to_owned)
        .map_err(|_| format!("{field} is not valid UTF-8"))
}

unsafe fn password_string(bytes: *const u8, length: usize) -> Result<String, String> {
    if length > MAX_CREDENTIAL_BYTES {
        return Err("password length is invalid".to_string());
    }
    if length == 0 {
        return Ok(String::new());
    }
    if bytes.is_null() {
        return Err("password is missing".to_string());
    }
    let value = slice::from_raw_parts(bytes, length);
    str::from_utf8(value)
        .map(str::to_owned)
        .map_err(|_| "password is not valid UTF-8".to_string())
}

unsafe fn optional_sql(bytes: *const u8, length: usize) -> Result<String, String> {
    if bytes.is_null() || length == 0 || length > MAX_SQL_BYTES {
        return Err("query length is invalid".to_string());
    }
    let value = slice::from_raw_parts(bytes, length);
    str::from_utf8(value)
        .map(str::to_owned)
        .map_err(|_| "query is not valid UTF-8".to_string())
}

fn detect_server_encoding(client: &mut Client) -> Result<(), String> {
    let result = client
        .query("SELECT UNICODE()")
        .map_err(|error| error.to_string())?;
    let row = result
        .rows
        .first()
        .ok_or_else(|| "DM8 did not return its Unicode mode".to_string())?;
    let flag = row.get_i32(0).map_err(|error| error.to_string())?;
    client.server_encoding = if flag == 1 {
        ServerEncoding::Utf8
    } else {
        ServerEncoding::Gb18030
    };
    Ok(())
}

fn text_cell(value: impl ToString) -> TpDmCell {
    TpDmCell::Text(value.to_string().into_bytes())
}

fn is_lob_column(column: &dameng::row::Column) -> bool {
    matches!(
        DmValueType::from_type_code(column.type_code),
        Some(DmValueType::BLOB) | Some(DmValueType::CLOB)
    )
}

fn undecoded_cell(row: &dameng::Row, index: usize) -> TpDmCell {
    match row.values.get(index).and_then(Option::as_ref) {
        Some(raw) if !raw.is_empty() => TpDmCell::Bytes(raw.clone()),
        _ => TpDmCell::Null,
    }
}

/// A value DM8 stored away from the row arrives as a locator, a pointer the client is meant to
/// dereference with LOB_GETLEN and LOB_READ. That exchange is not implemented correctly here:
/// measured against DM8 8.1, reading a 1000 character CLOB makes the server close the
/// connection. Reporting the cell empty keeps the rest of the row, and the connection, intact.
/// A small value DM8 sends inline is not a locator and still reads normally.
fn convert_cell(
    row: &dameng::Row,
    columns: &[dameng::row::Column],
    index: usize,
) -> Result<TpDmCell, dameng::Error> {
    let is_lob = columns.get(index).is_some_and(is_lob_column);
    let Some(value) = row.get(index, columns) else {
        // The raw bytes of a large-object cell are its locator, so handing them over would
        // render a pointer as though it were the stored text.
        return Ok(if is_lob {
            TpDmCell::Null
        } else {
            undecoded_cell(row, index)
        });
    };
    match value {
        DmValue::Null => Ok(TpDmCell::Null),
        DmValue::Boolean(value) => Ok(text_cell(if value { "1" } else { "0" })),
        DmValue::TinyInt(value) => Ok(text_cell(value)),
        DmValue::SmallInt(value) => Ok(text_cell(value)),
        DmValue::Int(value) => Ok(text_cell(value)),
        DmValue::BigInt(value) => Ok(text_cell(value)),
        DmValue::Float(value) => Ok(text_cell(value)),
        DmValue::Double(value) => Ok(text_cell(value)),
        DmValue::Text(value) => Ok(TpDmCell::Text(value.into_bytes())),
        DmValue::Bytea(value) => Ok(TpDmCell::Bytes(value)),
        DmValue::Decimal(value) => Ok(text_cell(value)),
        DmValue::Date(value) => Ok(text_cell(value)),
        DmValue::Time(value) => Ok(text_cell(value)),
        DmValue::Timestamp(value) => Ok(text_cell(value)),
        DmValue::LobLocator(_) => Ok(TpDmCell::Null),
    }
}

/// Reads the rest of a result set off the cursor.
///
/// DM8 answers a query with one inline batch, around 32KB of it, and holds the rest until the
/// client asks. Stopping at the first batch silently returned 662 rows of a 20000 row table
/// while reporting the result complete. `row_cap` fetches one row past the cap so the caller
/// can tell "exactly this many rows" from "more than the caller asked for".
fn drain_cursor(
    client: &mut Client,
    result: &mut dameng::ResultSet,
    row_cap: usize,
) -> Result<(), dameng::Error> {
    let fetch_limit = if row_cap > 0 {
        row_cap.saturating_add(1)
    } else {
        usize::MAX
    };
    while !result.complete && result.rows.len() < fetch_limit {
        let previous_count = result.rows.len();
        client.fetch_more(result, previous_count, 65_536)?;
        if result.rows.len() == previous_count {
            break;
        }
    }
    Ok(())
}

fn query_result(
    client: &mut Client,
    sql: &str,
    row_cap: usize,
) -> Result<TpDmResult, dameng::Error> {
    let started = Instant::now();
    let mut result = client.query(sql)?;
    drain_cursor(client, &mut result, row_cap)?;
    let columns = result
        .columns
        .iter()
        .map(|column| TpDmColumn {
            name: column.name.as_bytes().to_vec(),
            type_name: column.type_name.as_bytes().to_vec(),
        })
        .collect();
    let is_truncated = row_cap > 0 && (result.rows.len() > row_cap || !result.complete);
    let row_count = if row_cap > 0 {
        result.rows.len().min(row_cap)
    } else {
        result.rows.len()
    };
    let mut rows = Vec::with_capacity(row_count);
    for row in result.rows.iter().take(row_count) {
        let mut cells = Vec::with_capacity(result.columns.len());
        for index in 0..result.columns.len() {
            cells.push(convert_cell(row, &result.columns, index)?);
        }
        rows.push(cells);
    }
    let delivered_row_count = u64::try_from(rows.len()).unwrap_or(u64::MAX);
    Ok(TpDmResult {
        columns,
        rows,
        rows_affected: delivered_row_count,
        execution_time_seconds: started.elapsed().as_secs_f64(),
        is_truncated,
    })
}

/// Runs a statement the caller did not expect to return rows.
///
/// The caller's expectation only selects the protocol framing path. It does not decide what
/// the user sees: if the server answered with a result set anyway, the rows are converted and
/// returned rather than reduced to an affected count.
fn execute_result(
    client: &mut Client,
    sql: &str,
    row_cap: usize,
) -> Result<TpDmResult, dameng::Error> {
    let started = Instant::now();
    let mut result = client.execute_statement(sql)?;
    if result.columns.is_empty() {
        // Nothing to drain, and this is the DML path: `do_prepare_execute` has already sent the
        // COMMIT, so a FETCH here would run against a cursor whose transaction is closed.
        return Ok(TpDmResult {
            columns: Vec::new(),
            rows: Vec::new(),
            rows_affected: result.total_row_count,
            execution_time_seconds: started.elapsed().as_secs_f64(),
            is_truncated: false,
        });
    }
    // A statement the caller did not expect to return rows still has a cursor when it does,
    // and leaving it undrained truncated the answer to its first batch.
    drain_cursor(client, &mut result, row_cap)?;
    let columns = result
        .columns
        .iter()
        .map(|column| TpDmColumn {
            name: column.name.as_bytes().to_vec(),
            type_name: column.type_name.as_bytes().to_vec(),
        })
        .collect();
    let is_truncated = row_cap > 0 && (result.rows.len() > row_cap || !result.complete);
    let row_count = if row_cap > 0 {
        result.rows.len().min(row_cap)
    } else {
        result.rows.len()
    };
    let mut rows = Vec::with_capacity(row_count);
    for row in result.rows.iter().take(row_count) {
        let mut cells = Vec::with_capacity(result.columns.len());
        for index in 0..result.columns.len() {
            cells.push(convert_cell(row, &result.columns, index)?);
        }
        rows.push(cells);
    }
    let delivered_row_count = u64::try_from(rows.len()).unwrap_or(u64::MAX);
    Ok(TpDmResult {
        columns,
        rows,
        rows_affected: delivered_row_count,
        execution_time_seconds: started.elapsed().as_secs_f64(),
        is_truncated,
    })
}

fn connection_client(connection: &mut TpDmConnection) -> Result<Client, String> {
    connection
        .client
        .take()
        .ok_or_else(|| "Dameng connection is closed".to_string())
}

fn restore_client(connection: &mut TpDmConnection, client: Client) {
    connection.client = Some(client);
}

fn dispose(connection: &mut TpDmConnection, mut client: Client, keep_open: bool) {
    if keep_open {
        restore_client(connection, client);
    } else {
        let _ = client.close();
    }
}

/// Whether the connection can serve another statement after this failure.
///
/// Cancellation and timeout abandon the response mid-message, so the stream is desynced and
/// the next statement would read the abandoned reply as its own. Both close the connection.
fn is_recoverable(error: &dameng::Error) -> bool {
    !matches!(
        error,
        dameng::Error::Protocol(_)
            | dameng::Error::Io(_)
            | dameng::Error::ConnectionFailed(_)
            | dameng::Error::AuthFailed(_)
            | dameng::Error::NotConnected
            | dameng::Error::Timeout(_)
            | dameng::Error::Cancelled
    )
}

/// Distinguishes a caller-requested stop from a server or transport failure, so Swift can
/// raise `CancellationError` instead of surfacing an error the user did not cause.
fn is_cancellation(error: &dameng::Error) -> bool {
    matches!(error, dameng::Error::Cancelled)
}

#[no_mangle]
pub unsafe extern "C" fn tp_dm_connect(
    host: *const u8,
    host_length: usize,
    port: u16,
    username: *const u8,
    username_length: usize,
    password: *const u8,
    password_length: usize,
    error_out: *mut *mut TpDmError,
) -> *mut TpDmConnection {
    clear_error(error_out);
    let operation = catch_unwind(AssertUnwindSafe(|| -> Result<TpDmConnection, String> {
        if port == 0 {
            return Err("port must be greater than zero".to_string());
        }
        let host = required_string(host, host_length, MAX_HOST_BYTES, "host")?;
        let username =
            required_string(username, username_length, MAX_CREDENTIAL_BYTES, "username")?;
        let password = password_string(password, password_length)?;
        let mut client = Client::new(&host, port);
        client
            .connect(&username, &password)
            .map_err(|error| error.to_string())?;
        detect_server_encoding(&mut client)?;
        let interrupt = Arc::clone(&client.interrupt);
        Ok(TpDmConnection {
            client: Some(client),
            interrupt,
        })
    }));
    match operation {
        Ok(Ok(connection)) => Box::into_raw(Box::new(connection)),
        Ok(Err(message)) => {
            set_error(error_out, message);
            ptr::null_mut()
        }
        Err(payload) => {
            set_error(error_out, panic_message(payload));
            ptr::null_mut()
        }
    }
}

#[no_mangle]
pub unsafe extern "C" fn tp_dm_disconnect(connection: *mut TpDmConnection) {
    if connection.is_null() {
        return;
    }
    let _ = catch_unwind(AssertUnwindSafe(|| {
        let mut connection = Box::from_raw(connection);
        if let Some(mut client) = connection.client.take() {
            let _ = client.close();
        }
    }));
}

#[no_mangle]
pub unsafe extern "C" fn tp_dm_execute(
    connection: *mut TpDmConnection,
    sql: *const u8,
    sql_length: usize,
    expects_rows: bool,
    row_cap: usize,
    timeout_millis: u64,
    error_out: *mut *mut TpDmError,
) -> *mut TpDmResult {
    clear_error(error_out);
    if connection.is_null() {
        set_error(error_out, "Dameng connection is missing");
        return ptr::null_mut();
    }
    let sql = match optional_sql(sql, sql_length) {
        Ok(sql) => sql,
        Err(message) => {
            set_error(error_out, message);
            return ptr::null_mut();
        }
    };
    let connection = &mut *connection;
    let mut client = match connection_client(connection) {
        Ok(client) => client,
        Err(message) => {
            set_closed_error(error_out, message);
            return ptr::null_mut();
        }
    };
    connection.interrupt.reset();
    connection.interrupt.set_timeout_millis(timeout_millis);
    let operation = catch_unwind(AssertUnwindSafe(|| {
        if expects_rows {
            query_result(&mut client, &sql, row_cap)
        } else {
            execute_result(&mut client, &sql, row_cap)
        }
    }));
    connection.interrupt.reset();
    match operation {
        Ok(Ok(result)) => {
            restore_client(connection, client);
            Box::into_raw(Box::new(result))
        }
        Ok(Err(error)) => {
            dispose(connection, client, is_recoverable(&error));
            set_driver_error(error_out, &error);
            ptr::null_mut()
        }
        Err(payload) => {
            dispose(connection, client, false);
            set_closed_error(error_out, panic_message(payload));
            ptr::null_mut()
        }
    }
}

/// Asks an in-flight statement on `connection` to stop. Safe to call from any thread while
/// another thread is inside `tp_dm_execute`, which is the only way it does anything useful.
///
/// Stopping abandons the server's reply mid-message, so the connection is closed rather than
/// reused. Callers must treat a cancelled connection as disconnected.
#[no_mangle]
pub unsafe extern "C" fn tp_dm_cancel(connection: *const TpDmConnection) {
    if connection.is_null() {
        return;
    }
    let _ = catch_unwind(AssertUnwindSafe(|| {
        (*connection).interrupt.cancel();
    }));
}

unsafe fn transaction_operation(
    connection: *mut TpDmConnection,
    error_out: *mut *mut TpDmError,
    operation: impl FnOnce(&mut Client) -> Result<(), dameng::Error>,
) -> bool {
    clear_error(error_out);
    if connection.is_null() {
        set_error(error_out, "Dameng connection is missing");
        return false;
    }
    let connection = &mut *connection;
    let mut client = match connection_client(connection) {
        Ok(client) => client,
        Err(message) => {
            set_closed_error(error_out, message);
            return false;
        }
    };
    let result = catch_unwind(AssertUnwindSafe(|| operation(&mut client)));
    match result {
        Ok(Ok(())) => {
            restore_client(connection, client);
            true
        }
        Ok(Err(error)) => {
            dispose(connection, client, is_recoverable(&error));
            set_driver_error(error_out, &error);
            false
        }
        Err(payload) => {
            dispose(connection, client, false);
            set_closed_error(error_out, panic_message(payload));
            false
        }
    }
}

#[no_mangle]
pub unsafe extern "C" fn tp_dm_begin(
    connection: *mut TpDmConnection,
    error_out: *mut *mut TpDmError,
) -> bool {
    transaction_operation(connection, error_out, Client::begin)
}

#[no_mangle]
pub unsafe extern "C" fn tp_dm_commit(
    connection: *mut TpDmConnection,
    error_out: *mut *mut TpDmError,
) -> bool {
    transaction_operation(connection, error_out, Client::commit)
}

#[no_mangle]
pub unsafe extern "C" fn tp_dm_rollback(
    connection: *mut TpDmConnection,
    error_out: *mut *mut TpDmError,
) -> bool {
    transaction_operation(connection, error_out, Client::rollback)
}

#[no_mangle]
pub unsafe extern "C" fn tp_dm_ping(
    connection: *mut TpDmConnection,
    error_out: *mut *mut TpDmError,
) -> bool {
    transaction_operation(connection, error_out, |client| client.ready())
}

#[no_mangle]
pub unsafe extern "C" fn tp_dm_result_free(result: *mut TpDmResult) {
    if !result.is_null() {
        drop(Box::from_raw(result));
    }
}

#[no_mangle]
pub unsafe extern "C" fn tp_dm_error_free(error: *mut TpDmError) {
    if !error.is_null() {
        drop(Box::from_raw(error));
    }
}

#[no_mangle]
pub unsafe extern "C" fn tp_dm_error_is_cancellation(error: *const TpDmError) -> bool {
    if error.is_null() {
        return false;
    }
    (*error).cancelled
}

#[no_mangle]
pub unsafe extern "C" fn tp_dm_error_is_connection_lost(error: *const TpDmError) -> bool {
    if error.is_null() {
        return false;
    }
    (*error).connection_lost
}

#[no_mangle]
pub unsafe extern "C" fn tp_dm_error_message(
    error: *const TpDmError,
    length_out: *mut usize,
) -> *const u8 {
    if error.is_null() {
        return ptr::null();
    }
    let message = &(*error).message;
    if !length_out.is_null() {
        *length_out = message.len();
    }
    message.as_ptr()
}

#[no_mangle]
pub unsafe extern "C" fn tp_dm_result_column_count(result: *const TpDmResult) -> usize {
    result
        .as_ref()
        .map(|result| result.columns.len())
        .unwrap_or(0)
}

#[no_mangle]
pub unsafe extern "C" fn tp_dm_result_row_count(result: *const TpDmResult) -> usize {
    result.as_ref().map(|result| result.rows.len()).unwrap_or(0)
}

#[no_mangle]
pub unsafe extern "C" fn tp_dm_result_rows_affected(result: *const TpDmResult) -> u64 {
    result
        .as_ref()
        .map(|result| result.rows_affected)
        .unwrap_or(0)
}

#[no_mangle]
pub unsafe extern "C" fn tp_dm_result_execution_time(result: *const TpDmResult) -> f64 {
    result
        .as_ref()
        .map(|result| result.execution_time_seconds)
        .unwrap_or(0.0)
}

#[no_mangle]
pub unsafe extern "C" fn tp_dm_result_is_truncated(result: *const TpDmResult) -> bool {
    result
        .as_ref()
        .map(|result| result.is_truncated)
        .unwrap_or(false)
}

unsafe fn column_bytes(
    result: *const TpDmResult,
    column_index: usize,
    length_out: *mut usize,
    value: impl FnOnce(&TpDmColumn) -> &[u8],
) -> *const u8 {
    let Some(column) = result
        .as_ref()
        .and_then(|result| result.columns.get(column_index))
    else {
        return ptr::null();
    };
    let bytes = value(column);
    if !length_out.is_null() {
        *length_out = bytes.len();
    }
    bytes.as_ptr()
}

#[no_mangle]
pub unsafe extern "C" fn tp_dm_result_column_name(
    result: *const TpDmResult,
    column_index: usize,
    length_out: *mut usize,
) -> *const u8 {
    column_bytes(result, column_index, length_out, |column| &column.name)
}

#[no_mangle]
pub unsafe extern "C" fn tp_dm_result_column_type(
    result: *const TpDmResult,
    column_index: usize,
    length_out: *mut usize,
) -> *const u8 {
    column_bytes(result, column_index, length_out, |column| &column.type_name)
}

#[no_mangle]
pub unsafe extern "C" fn tp_dm_result_cell_kind(
    result: *const TpDmResult,
    row_index: usize,
    column_index: usize,
) -> i32 {
    let Some(cell) = result
        .as_ref()
        .and_then(|result| result.rows.get(row_index))
        .and_then(|row| row.get(column_index))
    else {
        return -1;
    };
    match cell {
        TpDmCell::Null => 0,
        TpDmCell::Text(_) => 1,
        TpDmCell::Bytes(_) => 2,
    }
}

#[no_mangle]
pub unsafe extern "C" fn tp_dm_result_cell_bytes(
    result: *const TpDmResult,
    row_index: usize,
    column_index: usize,
    length_out: *mut usize,
) -> *const u8 {
    let Some(cell) = result
        .as_ref()
        .and_then(|result| result.rows.get(row_index))
        .and_then(|row| row.get(column_index))
    else {
        return ptr::null();
    };
    let bytes = match cell {
        TpDmCell::Null => return ptr::null(),
        TpDmCell::Text(bytes) | TpDmCell::Bytes(bytes) => bytes,
    };
    if !length_out.is_null() {
        *length_out = bytes.len();
    }
    bytes.as_ptr()
}
