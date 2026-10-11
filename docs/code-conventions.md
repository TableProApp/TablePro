# Code conventions

`AGENTS.md` states the rules that make a change acceptable. This document states the rules that make two changes agree with each other. Its purpose is to settle recurring choices once, so a later change does not reverse an earlier one for no reason other than a different author on a different day.

If a rule here and `AGENTS.md` disagree, `AGENTS.md` wins and this document is wrong and must be fixed.

## Function shape

A function answers one question or performs one step. Its name says which. When you cannot name it without "and", it is two functions.

Order the body as: reject invalid input, resolve what you need, do the work, return. Put the rejections first as early returns so the working part of the function is never indented behind them.

```rust
fn parse_limit(raw: &str) -> Result<usize, FilterError> {
    let trimmed = raw.trim();
    if trimmed.is_empty() {
        return Err(FilterError::MissingLimit);
    }
    let parsed = trimmed.parse().map_err(|_| FilterError::NotANumber)?;
    if parsed > MAX_QUERY_ROWS {
        return Err(FilterError::LimitTooLarge(parsed));
    }
    Ok(parsed)
}
```

### Length

A function body may be at most **60 lines**, counted between its braces.

This is enforced by `scripts/check-function-size.py`, which runs in `preflight.sh`. Existing longer functions are frozen by count per file in `baselines/function-size-baselines.txt`. A file listed there may not gain another over-limit function, and when you split one you lower its count in the same commit. Test code is excluded: `#[cfg(test)]` modules and files under a crate's `tests/`.

Sixty is deliberately generous. The measured median function body in this workspace is 8 lines and the 90th percentile outside `app/src/ui` is about 25. Reaching 60 is a signal, not a budget to spend.

### Parameters

Five parameters is the point where you justify yourself, and `self` counts. Ninety percent of functions here take three or fewer. Past five, pass a struct, or the function is doing two jobs.

Prefer `&str` over `&String`, `&[T]` over `&Vec<T>`, and an owned parameter only when the callee stores it.

### Nesting

Three levels of indentation inside a function body is the limit before you extract. `let ... else`, `?`, and early `return` remove most nesting in this codebase; reach for those before a nested `match`.

### Naming

- A function returning a value is named for the value: `forwarded_socket_name`, `default_level`.
- A predicate starts with `is_`, `has_`, `supports_`, or `looks_like_`, and returns `bool` with no side effect.
- A function that constructs a widget tree starts with `build_`.
- A function that performs work for a message starts with `handle_` or `on_`.
- A constructor is `new` when it cannot fail, `open`/`connect`/`load` when it performs I/O, and `try_new` only when `new` already exists.
- A test is a sentence about behaviour: `a_filtered_delete_removes_only_the_matching_documents`. Not `test_delete`.

## GTK construction is the known exception

Fifty-nine of the eighty-nine functions currently over the limit live in `apps/linux/app/src/ui`. Relm4 `init`, `update`, and `build_*` functions accumulate widget wiring that has no natural seam, and splitting them arbitrarily produces helpers that are called once and read worse than the original.

The exception is narrow. It covers only widget construction and message dispatch. It does not cover logic that happens to sit inside them. When an `update` arm computes something, that computation moves to a free function in a sibling module and gets a unit test, which is the rule `AGENTS.md` already states as "keep reusable logic outside widget construction".

The baseline file does not distinguish these from the rest, on purpose. A UI file at its baseline still cannot grow.

## SOLID, stated as rules for this workspace

The letters are only useful here as five specific obligations.

**Single responsibility.** A module owns one concern and its name says which. `crates/policy/src/classify.rs` classifies statements and does not evaluate rules. When a module's name needs "and" or "util", split it. This applies at file level, which is why `check-file-size.sh` exists: a 1,200-line file has almost always accumulated a second responsibility.

**Open/closed.** Register engines through static driver crates and the owning composition roots, following [the driver guide](adding-drivers.md). Shared SQL builders, policy classifiers and grid parsers already have dialect-specific branches. Extend those only for a concrete native contract and update affected consumers together. Reuse a capability where one exists; repeated dialect branches alone do not justify a new abstraction.

**Liskov.** Every `Connection` implementation must honour the trait's documented contract, including its failure contract. A driver that cannot cancel server side reports that through the capability it advertises. It does not silently return `Ok` from a method it did not perform.

**Interface segregation.** Keep trait additions tied to a concrete consumer. Use existing capabilities for optional behavior. A shared method may be extended when every wrapper forwards it and unsupported drivers refuse safely; a separate trait is useful only when its ownership and callers justify it.

**Dependency inversion.** Dependencies point at `core`. `core` depends on no workspace crate, `policy` on `core` only, and domain crates never import GTK or Relm4. A service takes a trait object or a generic, not a concrete driver, which is what makes `PolicyGuard` testable against a fake connection.

## Duplication, stated as rules

"Don't repeat yourself" is about knowledge, not about text. Two functions that look alike but would change for different reasons are not duplication, and merging them creates a function with a boolean parameter that nobody can read.

**Extract on the third occurrence, not the second.** Two similar blocks are evidence. Three are a rule. Copy the second one and wait.

**Extract when a change must be made in more than one place to stay correct.** This is the real test, and it overrides the rule of three. If forgetting one copy is a bug rather than an inconsistency, share it now. Parameter binding, identifier quoting, value rendering, and policy classification are all in this category.

**Do not extract across a crate boundary to save lines.** Shared code in `core` is a contract every driver must keep. `error_chain_text` earned its place there because every driver must classify a TLS failure the same way, not because two drivers had similar code. If only two want it and a third would be wrong to use it, leave the two copies and say so in the commit.

**Never share a constant by importing it sideways.** A driver reading another driver's constant is a dependency the manifest does not show.

## Errors

Every crate boundary returns a typed `thiserror` enum. A variant names what failed in the caller's vocabulary, not the library's. Wrap a foreign error as a `#[from]` source rather than formatting it into a string, so the chain survives.

`DriverError::OperationOutcomeUnknown` means an interrupted/dispatched operation whose terminal outcome cannot be confirmed. Controlled reads can return it too; only a governed write poisons write state. Pre-dispatch refusal is a known outcome, and an ambiguous write must not become a plain failure.

Never put a secret, SQL parameter, connection string, unmasked result or raw panic payload in returned errors, audit fields or logs. `tracing` at `error` does not make sensitive data safe. See [the privacy rule](error-handling.md#logging).

## Settled decisions

These are the choices that have been made more than once. They are settled. If you want to change one, change it here first, in its own commit, with the reason. Do not change it in passing inside a feature commit.

| Question | Settled answer | Recorded |
| --- | --- | --- |
| Where does a driver panic get caught? | `PolicyGuard`, once, for every consumer | [ADR 0006](decisions/0006-driver-panic-containment.md) |
| How does a service reach a component? | An `Arc`-shared service handle, not a global | [state-management](state-management.md) |
| Whole-value state versus per-key state | `StateFile<T>` for whole documents, `WorkspaceStore` for per-connection merge | [state-management](state-management.md) |
| Is a comment allowed? | Only for behaviour outside this repository | `AGENTS.md` |
| Optional behaviour on a trait | Existing capability first; shared extension requires concrete callers and wrapper review | this document |
| A cell the driver could not decode | `Value::Undecodable` carrying the type name, never `Value::Null` | [ADR 0007](decisions/0007-type-and-value-preservation.md) |
| Cancellation | Reaches the database operation, not just the future | [ADR 0005](decisions/0005-server-side-cancellation.md) |

When a question is answered twice in opposite directions, that is the signal to add a row here rather than to argue the third time.

## Changing a convention

A convention change is its own commit, touching this document and the script that enforces it, with no behaviour change alongside it. A limit is lowered by fixing the code first and lowering the number in the same commit. A limit is not raised; the code is split instead.
