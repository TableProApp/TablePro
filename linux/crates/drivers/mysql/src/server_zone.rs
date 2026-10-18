//! Which time zone a workspace connection is in, and when.
//!
//! A TIMESTAMP is an instant, but the server reads and writes it as wall
//! time in the session's `time_zone`, and evaluates `CURRENT_TIMESTAMP`
//! and `NOW()` in that zone too. One zone cannot serve both:
//!
//! - Reads run in `+00:00`, the zone a workspace session opens in. UTC
//!   has no repeated hour, so every TIMESTAMP reads as the exact instant
//!   it holds.
//! - Saves and schema changes run in the server's own zone,
//!   `@@GLOBAL.time_zone`, the one the mysql client and every other
//!   client that sets none gets. A `DATETIME DEFAULT CURRENT_TIMESTAMP`
//!   or `ON UPDATE CURRENT_TIMESTAMP` then stores the wall time other
//!   clients store, and an ALTER between DATETIME and TIMESTAMP reads
//!   and writes the wall times they mean. A write batch switches the
//!   zone before its first statement and puts `+00:00` back after its
//!   last; a connection where that fails is closed, never pooled.
//! - A TIMESTAMP value is bound as its UTC wall time inside
//!   [`TIMESTAMP_PLACEHOLDER`], which converts it to the session's zone.
//!   On a read the conversion does nothing; on a write it gives the wall
//!   time the server turns back into the same instant.
//!
//! That last step has one gap. In the hour a zone with daylight saving
//! repeats in autumn, one wall time names two instants and the server
//! picks one: MySQL 8.4 and MariaDB 11.4 both store 05:30Z for 06:30Z
//! in America/New_York, and a key compared there matches the other row.
//! So before a write sends anything, each instant it binds is converted
//! to the server's zone and back; one that does not come back the same
//! refuses the whole batch. A zone written as a fixed offset has no such
//! hour and skips the check.
//!
//! A TIMESTAMP column's constant default is restated by every MODIFY of
//! the column, so the structure tab reads it in the server's zone too
//! (`metadata::timestamp_default`).

use chrono::NaiveDateTime;
use sqlx::mysql::MySqlConnection;
use sqlx::{AssertSqlSafe, Executor as _, Row as _};
use tablepro_core::DriverError;
use tablepro_core::statement::{BoundParam, GuardedStatement};
use tablepro_core::value::{Temporal, Value};

use crate::decode::decode_row;
use crate::errors::map_error;
use crate::flavour::MySqlFlavour;
use crate::mysql_timestamp_mode::MySqlTimestampMode;
use crate::mysql_wire_format::MySqlWireFormat;

/// Where a write batch runs.
pub(crate) const SERVER_ZONE_STATEMENT: &str = "SET SESSION time_zone = @@GLOBAL.time_zone";

/// Where a workspace connection reads, put back after a write.
pub(crate) const READ_ZONE_STATEMENT: &str = "SET SESSION time_zone = '+00:00'";

/// A TIMESTAMP parameter, bound as UTC wall time.
pub(crate) const TIMESTAMP_PLACEHOLDER: &str = "CONVERT_TZ(?, '+00:00', @@session.time_zone)";

/// How the refusal reads: "This database has no {feature}."
const REPEATED_HOUR: &str = "single instant for a TIMESTAMP in the hour its time zone repeats";

/// Instants checked per round trip. Each is bound twice, far inside
/// the server's 65,535 placeholders.
const CHECK_CHUNK: usize = 100;

/// The step that binds an instant the session's zone cannot hold apart
/// from another, if any. Run after [`SERVER_ZONE_STATEMENT`] and before
/// anything is written.
pub(crate) async fn repeated_instant(
    connection: &mut MySqlConnection,
    flavour: MySqlFlavour,
    steps: &[GuardedStatement],
) -> Result<Option<usize>, DriverError> {
    let mut instants: Vec<(NaiveDateTime, usize)> = Vec::new();
    for (index, step) in steps.iter().enumerate() {
        for instant in step_instants(step) {
            if !instants.iter().any(|(seen, _)| *seen == instant) {
                instants.push((instant, index));
            }
        }
    }
    if instants.is_empty() || has_fixed_offset(&session_zone(connection, flavour).await?) {
        return Ok(None);
    }
    for chunk in instants.chunks(CHECK_CHUNK) {
        let mut query = sqlx::query(AssertSqlSafe(round_trip_sql(chunk.len()))).persistent(false);
        for (instant, _) in chunk {
            query = query.bind(*instant).bind(*instant);
        }
        let row = query
            .fetch_one(&mut *connection)
            .await
            .map_err(|error| map_error(&error, flavour))?;
        let kept = decode_row(&row, MySqlWireFormat::Binary, MySqlTimestampMode::WorkspaceUtc);
        let lost = chunk
            .iter()
            .zip(kept)
            .find(|(_, kept)| *kept != Value::Int(1))
            .map(|((_, step), _)| *step);
        if lost.is_some() {
            return Ok(lost);
        }
    }
    Ok(None)
}

/// The refusal for a batch [`repeated_instant`] found a step in.
pub(crate) fn repeated_hour() -> DriverError {
    DriverError::Unsupported { feature: REPEATED_HOUR }
}

/// Every finite instant a step binds, its probe's included.
fn step_instants(step: &GuardedStatement) -> impl Iterator<Item = NaiveDateTime> + '_ {
    let probe: &[BoundParam] = step.guard.probe().map_or(&[], |(probe, _)| probe.params());
    step.statement
        .params()
        .iter()
        .chain(probe)
        .filter_map(|param| match param.value() {
            Value::TimestampTz(Temporal::Finite(stamp)) => Some(stamp.utc()),
            _ => None,
        })
}

/// One column per instant, 1 where it comes back from the session's
/// zone as itself.
fn round_trip_sql(instants: usize) -> String {
    let column = "CONVERT_TZ(CONVERT_TZ(?, '+00:00', @@session.time_zone), @@session.time_zone, '+00:00') <=> ?";
    format!("SELECT {}", vec![column; instants].join(", "))
}

async fn session_zone(connection: &mut MySqlConnection, flavour: MySqlFlavour) -> Result<String, DriverError> {
    let row = connection
        .fetch_one(sqlx::raw_sql("SELECT @@session.time_zone"))
        .await
        .map_err(|error| map_error(&error, flavour))?;
    let bytes: &[u8] = row.try_get_unchecked(0).map_err(|error| DriverError::Decode {
        column: "@@session.time_zone".to_owned(),
        detail: error.to_string(),
    })?;
    Ok(String::from_utf8_lossy(bytes).into_owned())
}

/// `+07:00` and `-03:30` never repeat an hour; `SYSTEM` and a named zone
/// may.
fn has_fixed_offset(zone: &str) -> bool {
    zone.starts_with(['+', '-'])
}

#[cfg(test)]
mod tests {
    use chrono::NaiveDate;
    use tablepro_core::ServerInfo;
    use tablepro_core::column::{ColumnDefault, ColumnInfo, ColumnKind, ColumnType, ReadForm, TemporalZone};
    use tablepro_core::dialect::BindTarget;
    use tablepro_core::statement::{RowGuard, StatementBuilder};
    use tablepro_core::value::OffsetTimestamp;

    use super::*;
    use crate::dialect::MySqlDialect;
    use crate::workspace_session::WORKSPACE_TIME_ZONE;

    #[test]
    fn the_read_zone_is_the_one_the_session_opens_in() {
        assert!(READ_ZONE_STATEMENT.ends_with(&format!("'{WORKSPACE_TIME_ZONE}'")));
        assert!(TIMESTAMP_PLACEHOLDER.contains(&format!("'{WORKSPACE_TIME_ZONE}'")));
    }

    #[test]
    fn only_a_fixed_offset_skips_the_check() {
        assert!(has_fixed_offset("+07:00"));
        assert!(has_fixed_offset("-03:30"));
        assert!(!has_fixed_offset("SYSTEM"));
        assert!(!has_fixed_offset("Europe/Berlin"));
        assert!(!has_fixed_offset("UTC"));
    }

    fn stamp_column() -> ColumnInfo {
        ColumnInfo {
            name: "at".to_owned(),
            column_type: ColumnType {
                name: "timestamp".to_owned(),
                kind: ColumnKind::Timestamp {
                    fractional_digits: None,
                    zone: TemporalZone::Offset,
                },
                catalog: None,
                dynamic_storage: false,
                read_form: ReadForm::Native,
            },
            nullable: true,
            primary_key: false,
            is_auto_increment: false,
            is_generated: false,
            default: ColumnDefault::None,
            comment: None,
        }
    }

    fn statement(values: Vec<Value>) -> tablepro_core::statement::Statement {
        let dialect = MySqlDialect::new(MySqlFlavour::MySql, &ServerInfo::new("MySQL", "8.4.3", 8, 4, 3));
        let column = stamp_column();
        let mut builder = StatementBuilder::new();
        builder.push_sql("UPDATE t SET a = 1 WHERE at IN (");
        for value in values {
            builder
                .push_value(&dialect, value, BindTarget::Column(&column))
                .expect("a TIMESTAMP binds");
        }
        builder.push_sql(")");
        builder.finish()
    }

    fn at(hour: u32) -> Value {
        let stamp = NaiveDate::from_ymd_opt(2024, 11, 3)
            .and_then(|date| date.and_hms_opt(hour, 30, 0))
            .expect("a time");
        Value::TimestampTz(Temporal::Finite(OffsetTimestamp::from_datetime(
            stamp.and_utc().fixed_offset(),
        )))
    }

    #[test]
    fn every_instant_a_step_binds_is_checked() {
        let step = GuardedStatement {
            statement: statement(vec![at(5), Value::Null]),
            guard: RowGuard::ProbeExactly {
                probe: statement(vec![at(6)]),
                rows: 1,
            },
        };

        let hours: Vec<String> = step_instants(&step)
            .map(|stamp| stamp.format("%H").to_string())
            .collect();

        assert_eq!(hours, ["05", "06"]);
        assert_eq!(round_trip_sql(2).matches("<=> ?").count(), 2, "one column per instant");
    }
}
