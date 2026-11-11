# 0020: An int32 keeps its width, and an edited number keeps its type

- **Status**: Accepted
- **Date**: 2026-11-11

## Context

[Linux ADR 0014](../../../linux/docs/decisions/0014-lossless-values-and-dialects.md) gives `Value` one signed integer, `Int(i64)`, and leaves an integer's width to its column. That holds where the column declares a type. A MongoDB column is a census instead: the field's type over the first 1,000 documents, widened across `int`, `long`, `double` and `decimal` ([drivers/mongodb.md](../../../linux/docs/drivers/mongodb.md#catalogue)). The driver read an int32 and a long as the same `Int`, and an edit was parsed by the column's kind and bound by its type name. So an edit rewrote the cell's BSON type: an int32 in a `long` field became a long, an int32 or long in a `double` field a double, any number in a `decimal` field a Decimal128. A long past 2^53 in a `double` field lost digits, and a long past the census in an `int` field was refused. Copy as mongosh and Extended JSON wrote a long that fits 32 bits as an int.

## Decision

`Value::Int32(i32)` holds an int32 that an engine types apart from its column, and an edited number is written back in the type it was read as when the new value is exactly one of that type.

## Rationale

- **The width lives in the value.** ADR 0014 puts what the server sent in the value, with a variant per width where one matters (`Float32`, `Float64`). The read value already reaches the edit, the tracker and the FFI store, so only the int32 width was missing. Only the MongoDB driver produces `Int32`; every other engine keeps `Int` and the width on the column.
- **The same number either way.** `same_value`, `ValueIdentity`, `value::order` and the document brackets treat `Int32(n)` and `Int(n)` as one number, so an edit back to the read value is no edit and an `_id` key matches as MongoDB's index does.
- **The save carries the read value.** `RowUpdate::read` holds each assigned cell's read value, which the Linux tracker already kept as `CellEdit.original`. `document::bind_param` binds a number in the read's type when the new value is exactly a value of it: an integer in range, or a double whose shortest form is the decimal typed. Otherwise, and for a null, missing or new cell, the column's type applies. SQL engines ignore it.
- **The edit parses as the cell.** `parse_edit_text` takes the read value and parses as its number type first, but only where the column's kind does not hold the read, which a declared column never shows. So a long keeps its digits in a `double` field and is not refused in an `int` one.
- **Text writes the width.** Extended JSON writes `Int32` bare and `Int` as `$numberLong`; a mongosh literal writes `Int` as `NumberLong` unless the column is `int` and the value fits.
- **The FFI does not change.** `ValueKind::of_value` maps `Int32` to `Integer`; the result store keeps the width in a byte outside `ValueKind`, as it keeps a null, so a window still sends `Integer`.

## Consequences

- Every exhaustive match on `Value` has an `Int32` arm; each SQL driver binds and spells it as the integer it is.
- An edited int32 stays an int32, a long a long, a double a double and a Decimal128 a Decimal128, unless the new value is not one of those.
- A long that fits 32 bits in an `int` field, past the census, is still refused when edited past 32 bits: the column's range applies, since nothing tells it from an int.
- Windows sends `Integer` for an int32 cell. A save from Windows needs the read value with its width, which the core's result store holds.

## Alternatives considered

- **Any mix of numbers is a JSON column.** No `Value` change, but numeric fields lose number display and editing, and values past the census are still rewritten.
- **Read the document at save time.** A race between the read and the write, and the statement no longer shows what is sent, which the write confirmation compares.
- **A per-row type vector beside the rows.** Every layer that carries a cell would carry it too: the page, the grid, the tracker and the FFI store.
