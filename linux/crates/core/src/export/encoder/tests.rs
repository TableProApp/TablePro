use std::sync::Arc;

use super::super::csv::{csv_cell, csv_header, csv_writer_builder};
use super::super::csv_options::{CsvDecimal, CsvDelimiter, CsvLineBreak, CsvOptions, CsvQuote};
use super::super::test_columns::{cols, typed};
use super::super::tsv::tsv_writer_builder;
use super::super::value_text::value_text;
use super::super::{column_type, render_csv, render_json, render_tsv, row_to_json};
use super::*;
use crate::column::{ColumnKind, IntegerKind, IntegerWidth};
use crate::value::{JsonText, UndecodableReason, UndecodedValue};

/// Every call's output taken away as soon as it is written, the way a
/// sink hands each chunk on, so an encoder that leaned on what it wrote
/// earlier would show here.
fn streamed(mut encoder: impl RowEncoder, rows: &[Vec<Value>]) -> String {
    let mut taken = Vec::new();
    let mut out = Vec::new();
    encoder.begin(&mut out);
    taken.append(&mut out);
    for row in rows {
        encoder.row(&mut out, &mut row.iter()).expect("the row");
        taken.append(&mut out);
    }
    encoder.finish(&mut out);
    taken.append(&mut out);
    String::from_utf8(taken).expect("utf-8")
}

fn fixture() -> (Arc<[ResultColumn]>, Vec<Vec<Value>>) {
    let columns: Arc<[ResultColumn]> = vec![
        typed(
            "id",
            "bigint",
            ColumnKind::Integer(IntegerKind {
                width: IntegerWidth::W64,
                signed: true,
            }),
        ),
        typed(
            "amount",
            "numeric(10,2)",
            ColumnKind::Decimal {
                precision: Some(10),
                scale: Some(2),
            },
        ),
        cols(&["=note"]).remove(0),
    ]
    .into();
    let rows = vec![
        vec![
            Value::Int(-5),
            Value::Decimal("-1.5".parse().expect("a decimal")),
            Value::Text("=cmd|'/C calc'!A0".into()),
        ],
        vec![
            Value::Int(7),
            Value::Float64(2.25),
            Value::Text("line1\r\nline2, \"quoted\"\ttab".into()),
        ],
        vec![Value::Null, Value::Null, Value::Text(String::new())],
        vec![
            Value::UInt(u64::MAX),
            Value::Decimal("12.30".parse().expect("a decimal")),
            Value::Text("-12".into()),
        ],
    ];
    (columns, rows)
}

/// CSV as one writer over the whole result, the way it was written
/// before the encoders.
fn one_writer_csv(columns: &[ResultColumn], rows: &[Vec<Value>], options: &CsvOptions) -> String {
    let mut writer = csv_writer_builder(options).from_writer(Vec::new());
    if options.header_row {
        writer
            .write_record(columns.iter().map(|column| csv_header(&column.name, options)))
            .expect("the header");
    }
    for row in rows {
        writer
            .write_record(
                row.iter()
                    .enumerate()
                    .map(|(index, value)| csv_cell(value, column_type(columns, index), options)),
            )
            .expect("the row");
    }
    String::from_utf8(writer.into_inner().expect("flushed")).expect("utf-8")
}

#[test]
fn csv_encoder_matches_render_csv_fixture_matrix() {
    let (columns, rows) = fixture();
    let mut checked = 0;
    for header_row in [true, false] {
        for sanitize_formulas in [true, false] {
            for null_to_empty in [true, false] {
                for line_break_to_space in [true, false] {
                    for delimiter in CsvDelimiter::ALL {
                        for quote in CsvQuote::ALL {
                            for line_break in CsvLineBreak::ALL {
                                for decimal in CsvDecimal::ALL {
                                    let options = CsvOptions {
                                        null_to_empty,
                                        line_break_to_space,
                                        header_row,
                                        sanitize_formulas,
                                        delimiter,
                                        quote,
                                        line_break,
                                        decimal,
                                    };
                                    let expected = one_writer_csv(&columns, &rows, &options);

                                    let encoded = streamed(CsvEncoder::new(columns.clone(), options.clone()), &rows);

                                    assert_eq!(encoded, expected, "{options:?}");
                                    assert_eq!(
                                        render_csv(&columns, &rows, &options).expect("the csv"),
                                        expected,
                                        "{options:?}"
                                    );
                                    checked += 1;
                                }
                            }
                        }
                    }
                }
            }
        }
    }
    assert_eq!(checked, 2 * 2 * 2 * 2 * 4 * 3 * 3 * 2);
}

/// One writer serves the whole export, so a row wider than the header
/// must not trip the check a writer makes on record lengths.
#[test]
fn csv_and_tsv_encoders_take_rows_wider_than_the_header() {
    let columns: Arc<[ResultColumn]> = cols(&["a"]).into();
    let rows = vec![
        vec![Value::Int(1)],
        vec![Value::Int(2), Value::Int(3)],
        vec![Value::Int(4)],
    ];
    let options = CsvOptions {
        sanitize_formulas: false,
        ..CsvOptions::default()
    };

    assert_eq!(
        streamed(CsvEncoder::new(columns.clone(), options), &rows),
        "a\n1\n2,3\n4\n"
    );
    assert_eq!(streamed(TsvEncoder::new(columns, true), &rows), "a\n1\n2\t3\n4\n");
}

#[test]
fn tsv_encoder_matches_render_tsv() {
    let (columns, rows) = fixture();
    for with_headers in [true, false] {
        let mut writer = tsv_writer_builder().from_writer(Vec::new());
        if with_headers {
            writer
                .write_record(columns.iter().map(|column| column.name.as_str()))
                .expect("the header");
        }
        for row in &rows {
            writer
                .write_record(row.iter().enumerate().map(|(index, value)| {
                    value_text(value, column_type(&columns, index)).unwrap_or_else(|| "NULL".to_owned())
                }))
                .expect("the row");
        }
        let expected = String::from_utf8(writer.into_inner().expect("flushed")).expect("utf-8");

        assert_eq!(
            streamed(TsvEncoder::new(columns.clone(), with_headers), &rows),
            expected
        );
        assert_eq!(render_tsv(&columns, &rows, with_headers).expect("the tsv"), expected);
    }
}

#[test]
fn json_encoder_output_parses_and_matches_render_json() {
    const CHUNK: usize = 64 * 1024;
    let columns: Arc<[ResultColumn]> = cols(&["id", "name", "payload"]).into();
    let rows: Vec<Vec<Value>> = (0..10_000)
        .map(|id| {
            vec![
                Value::Int(id),
                Value::Text(format!("row \"{id}\"\n")),
                Value::Json(JsonText::parse(format!("{{\"n\": {id}}}")).expect("valid json")),
            ]
        })
        .collect();

    let mut encoder = JsonArrayEncoder::new(columns.clone());
    let mut chunks: Vec<Vec<u8>> = Vec::new();
    let mut out = Vec::with_capacity(CHUNK);
    encoder.begin(&mut out);
    for row in &rows {
        encoder.row(&mut out, &mut row.iter()).expect("the row");
        if out.len() >= CHUNK {
            chunks.push(std::mem::replace(&mut out, Vec::with_capacity(CHUNK)));
        }
    }
    encoder.finish(&mut out);
    chunks.push(out);

    assert!(chunks.len() > 2, "the export fit in one buffer");
    assert!(chunks[..chunks.len() - 1].iter().all(|chunk| chunk.len() >= CHUNK));
    let text = String::from_utf8(chunks.concat()).expect("utf-8");
    // render_json runs this encoder into one buffer, so this shows only
    // that the chunks change nothing.
    assert_eq!(text, render_json(&columns, &rows).expect("the json"));
    let parsed: Vec<serde_json::Value> = serde_json::from_str(&text).expect("a JSON array");
    // The values themselves, against the serializer that wrote whole
    // rows before the encoders.
    let expected: Vec<serde_json::Value> = rows
        .iter()
        .map(|row| serde_json::from_str(&row_to_json(&columns, row)).expect("a JSON row"))
        .collect();
    assert_eq!(parsed, expected);
    assert_eq!(parsed.len(), 10_000);
    assert_eq!(parsed[9_999]["id"], serde_json::json!(9_999));
    assert_eq!(parsed[3]["name"], serde_json::json!("row \"3\"\n"));
    assert_eq!(parsed[3]["payload"]["n"], serde_json::json!(3));
}

#[test]
fn json_encoder_keeps_column_order_without_preserve_order() {
    let columns: Arc<[ResultColumn]> = cols(&["b", "a", "c"]).into();
    let rows = vec![vec![Value::Int(1), Value::Int(2), Value::Int(3)]];

    assert_eq!(
        streamed(JsonArrayEncoder::new(columns), &rows),
        "[\n{\"b\":1,\"a\":2,\"c\":3}\n]"
    );
}

#[test]
fn json_encoder_duplicate_column_names_use_suffixes() {
    let columns: Arc<[ResultColumn]> = cols(&["id", "name", "id"]).into();
    let rows = vec![
        vec![Value::Int(1), Value::Text("a".into()), Value::Int(2)],
        vec![Value::Int(3), Value::Null, Value::Int(4)],
    ];

    assert_eq!(
        streamed(JsonArrayEncoder::new(columns), &rows),
        "[\n{\"id\":1,\"name\":\"a\",\"id_2\":2},\n{\"id\":3,\"name\":null,\"id_2\":4}\n]"
    );
}

#[test]
fn empty_json_export_is_empty_array() {
    let columns: Arc<[ResultColumn]> = cols(&["a"]).into();

    assert_eq!(streamed(JsonArrayEncoder::new(columns), &[]), "[]");
}

#[test]
fn encoder_reports_undecodable_cell() {
    let columns: Arc<[ResultColumn]> = cols(&["id", "shape"]).into();
    let undecodable = Value::Undecodable(Box::new(UndecodedValue {
        type_name: "geometry".to_owned(),
        reason: UndecodableReason::UnsupportedType,
    }));
    let encoders: Vec<Box<dyn RowEncoder>> = vec![
        Box::new(CsvEncoder::new(columns.clone(), CsvOptions::default())),
        Box::new(TsvEncoder::new(columns.clone(), true)),
        Box::new(JsonArrayEncoder::new(columns.clone())),
        Box::new(MarkdownEncoder::new(columns.clone())),
    ];
    for mut encoder in encoders {
        let mut out = Vec::new();
        encoder.begin(&mut out);
        let before = out.clone();

        let error = encoder
            .row(&mut out, &mut [Value::Int(1), undecodable.clone()].iter())
            .expect_err("an undecodable cell");

        assert_eq!(
            error,
            EncodeError::Undecodable {
                column: "shape".to_owned()
            }
        );
        assert_eq!(out, before, "a failed row left part of itself behind");
    }
}

#[test]
fn csv_neutralises_text_not_negative_numbers_through_encoder() {
    let columns: Arc<[ResultColumn]> = cols(&["a"]).into();
    let rows = vec![
        vec![Value::Text("=cmd".into())],
        vec![Value::Text("-cmd".into())],
        vec![Value::Int(-5)],
        vec![Value::Decimal("-12.30".parse().expect("a decimal"))],
        vec![Value::Float64(-1.5)],
        vec![Value::Text("-12".into())],
    ];

    let out = streamed(CsvEncoder::new(columns, CsvOptions::default()), &rows);

    assert_eq!(
        out,
        "\"a\"\n\"'=cmd\"\n\"'-cmd\"\n\"-5\"\n\"-12.30\"\n\"-1.5\"\n\"-12\"\n"
    );
}
