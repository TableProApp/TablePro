# 0007: Preserve native type and value semantics across consumers

- **Status**: Accepted
- **Date**: 2026-10-03
- **Origin**: Extraction of the approved B3 sprint and type-contract rules;
  no new value representation or completed-support claim.

## Context

A successful query or matching display text can hide a changed native type,
rounded number, shifted timestamp, altered binary encoding or substituted NULL.
The sprint and several evidence ledgers repeated these rules, making it easy
for a later session to implement a different conversion policy.

## Decision

This ADR is the shared type/value standard for drivers, core, grid editing,
filters, bound parameters, SQL literals, import/export and MCP. Architecture
rules live here; [the B3 board](../type-contract-strategy.md) tracks open work
and [the value index](../value-contracts.md) points to case evidence.

### Four explicit outcomes

Assess each **engine + native type + consumer + session configuration**:

| Outcome | Required meaning |
| --- | --- |
| Exact typed support | Native type semantics and value survive the named path, with an independent oracle |
| Exact text fallback | An engine-specific representation preserves the value; native re-import uses validated destination metadata or an explicit typed cast. It is not native typed binding |
| Explicit refusal | The operation reports an unsupported/unrepresentable value and prevents a lossy write or restore claim |
| Untested | Evidence for this specific path/configuration is absent; another driver's or consumer's pass cannot fill it |

Refusal is a safety result, not completed support. Text fallback is not proof
of a generic string round trip. Missing evidence never becomes a pass.

### Representation and metadata

1. `Value::Null` means a native NULL. Empty text/bytes/collections, a missing
   source field, a failed decoder and an unsupported non-NULL cell stay distinct.
   Use `Value::Undecodable(type_name)` or a typed operation error for unsupported
   decoding. Never turn a failed conversion into NULL, zero, empty text or debug
   output presented as the original value.
2. Use the existing [Value and ColumnInfo](../../crates/core/src/query.rs)
   contracts. Preserve declared schema spelling where the catalog supplies it,
   nullability, defaults, key components, generated/identity flags and collation
   needed by consumers. Query-result type metadata may use a different driver
   vocabulary; record that distinction instead of pretending it is catalog DDL.
   Preserve column/row order, duplicate aliases, zero-row metadata and explicit
   truncation. A sampled schema does not prove collection-wide completeness.
   MongoDB browse columns come from a complete census at initial load and F5;
   pages reuse that connection-local type union, merge newly observed page
   types, and driver writes invalidate it. External changes are refreshed at
   F5 or incorporated when a page observes them.
3. Choose a carrier that can represent the engine's semantics exactly. Do not
   force every engine into the narrowest shared scalar. Existing exact text,
   bytes and tagged JSON/Extended JSON fallbacks remain valid when their native
   semantics and consumer behavior are proven. `Value::Int` alone does not
   preserve BSON Int32/Int64 width; plain JSON does not preserve every BSON kind.
4. A new declared-type field, variant or abstraction requires a concrete
   consumer and an atomic caller/wrapper/adaptor review. The sprint's deferred
   separate declared-type field is not permission to erase existing metadata.
   Internal type improvements do not authorize a wire/persistence format change.

### Conversion and mutation

5. Display formatting is separate from editable/raw values. Parsing and writes
   use the owning engine and destination metadata. Reject overflow, rounding,
   nonzero underflow, unsupported precision and ambiguous session-dependent
   conversion before dispatch. Preserve the row's complete key and refuse
   unsafe row identity. Do not overwrite generated/server-owned fields.
6. Bound parameters and SQL literals are separate paths, each requiring proof.
   Exact text binding may need a dialect-specific, validated typed cast.
   Session timezone, date/interval style, collation and SQL mode form part of
   that proof. A native server silently accepting/clamping input is not exactness.
7. Preserve semantics relevant to the native type: integer width/signedness;
   decimal precision/scale; floating signed zero, subnormals and special values;
   temporal units, offsets/eras and supported range; independent interval
   components; binary bytes/subtypes; nested kinds, NULL elements, dimensions
   and bounds. Numeric/display equality alone cannot prove these distinctions.
8. Each format must state its encoding and limits. Use exact text/tagged
   encodings where a format cannot represent a value natively, such as risky
   Excel numbers or extended BSON. An export/import claiming restoration must
   preserve the named semantics or refuse explicitly. Diagnostic views may
   show a labeled unsupported marker; that marker is not a restorable value.
   Preserve the existing destination on failed/cancelled atomic export. CSV
   NULL/empty and formula-protection conventions need matching parser evidence.

### Proof and completion

9. A case records native type, input/boundaries, session setup, consumer, expected
   representation and exact selector. Compare against an independent server
   type/byte/field oracle or independently constructed wire expectation; never
   use the converter under test as its own oracle. For edits/imports, assert the
   native persisted type/value, key identity and unchanged sibling rows/fields.
   For refusal, assert no lossy mutation or destination replacement occurred.
10. Reproduce defects before fixing them. Include valid/invalid neighbors and
    deterministic generated boundaries where appropriate; retain named failures.
    Register execution ownership and record SHA/fingerprints, command and result.
    Mutation misses/timeouts, unavailable logs and unrun native/UI/package gates
    stay open. A unit result does not certify installed GTK or all consumers.

## Rationale

One semantic contract prevents a correct decoder being followed by a lossy
grid/export/binder. Consumer-specific outcomes let the current shared carrier
remain useful without overstating unsupported native types. Independent native
oracles detect changes hidden by equal-looking strings or shared formatter bugs.

## Consequences

Support is tracked by type and consumer, not a driver-wide green badge. Exact
text and safe refusal may remain necessary while a native representation is
unsupported. Changes touch affected consumers together; tests can be larger
than a scalar equality assertion. B3 remains open until its scoped acceptance
is met. This record does not change production code or existing evidence.

## Alternatives considered

- **Coerce everything to shared scalars or strings:** loses widths, precision,
  native kind and configuration-dependent semantics.
- **NULL on decode failure:** disguises corruption as valid editable data.
- **One new universal type system before fixing consumers:** adds an abstraction
  without proving the actual conversion paths; extend only for a concrete need.
- **Per-driver/per-format policy:** permits contradictory conversions after the
  same decode. Engine-specific encodings follow this common outcome/proof rule.
