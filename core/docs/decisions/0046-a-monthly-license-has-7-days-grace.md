# 0046: A monthly self-hosted license has 7 days' grace

- **Status**: Accepted
- **Date**: 2026-11-24

## Context

[0044](0044-sync-through-one-service-run-by-us-or-on-premises.md) gives a license file 30 days' grace after `exp`, and [0045](0045-perpetual-monthly-and-multi-year-licenses.md) kept that for every type, monthly included. On 2026-11-24 the maintainer set a monthly file's grace to 7 days and kept 30 for the others. With 30 days, a monthly install that stopped paying would push for about another month.

## Decision

A license file states the end of its grace in a new `grace_until` claim: 7 days after `exp` on a monthly file, 30 days after `exp` on every other file that has one.

- `grace_until` is a NumericDate (RFC 7519 section 2), a private claim beside `maintenance_until`.
- A file with `exp` has `grace_until`, later than its `exp`. A perpetual file has neither. The server, `license install` and the apps refuse a file that breaks this.
- Past `grace_until`, pushes are refused with `license_expired`, and pulls and administration keep working, as 0044 says for the end of the grace.
- The apps take the grace from the same claim, so a Mac and its server agree on when pushes stop.
- Nothing else in 0045 changes: the 3 days past the paid period, the renewal fetch, the banner and the log events.

## Rationale

- The issuer knows the type it sold. The server and the apps compare one date and hold no table of types and days, as no plan or price lives in their code.
- A date, like `exp` and `maintenance_until`, needs no arithmetic in the verifiers.

## Consequences

- A monthly install that stops paying keeps pushing for 10 days after its paid month ends: the 3 days of 0045, then 7 days' grace.
- A missed renewal fetch on a monthly install has 10 days to succeed, not 33. The server logs each failed fetch (0045), and the banner starts at `exp`.
- tablepro-cloud's issuer writes `grace_until`, and its verifier and the core's read it in place of `exp` plus 30 days.

## Alternatives considered

- **A `license_type` of `monthly`, mapped to 7 days in the server and the apps.** Each verifier would carry a table of types and days.
- **A grace length in days.** Each verifier would add it to `exp`, where a date is compared as it stands.
- **Working out monthly from `exp` minus `nbf`.** A rule that guesses the type from the dates, and an evaluation file is about a month long too.
